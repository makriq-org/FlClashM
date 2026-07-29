package com.follow.clashx.service

import android.os.SystemClock
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.diagnostics.BoundedUtf8LineReader
import com.follow.clashx.common.diagnostics.DiagnosticLog
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

data class RuntimeNodeSpec(
    val nodeId: String,
    val type: String,
    val name: String,
    val host: String,
    val port: Int,
    val executablePath: String,
    val workingDirectory: String,
    val arguments: List<String>,
    val revision: String,
    val connectivityCheck: RuntimeNodeConnectivityCheck,
    val resolverFile: RuntimeNodeResolverFile?,
    val startupFailurePatterns: List<String>,
) {
    companion object {
        private const val MAX_STARTUP_FAILURE_PATTERNS = 16
        private const val MAX_STARTUP_FAILURE_PATTERN_LENGTH = 256

        fun fromJson(value: JSONObject, index: Int): RuntimeNodeSpec {
            fun requiredString(name: String): String =
                value.optString(name, "").trim().also {
                    require(it.isNotEmpty()) { "Runtime node $index is missing $name" }
                }

            val rawArguments = value.optJSONArray("arguments") ?: JSONArray()
            val arguments = buildList {
                for (argumentIndex in 0 until rawArguments.length()) {
                    add(rawArguments.getString(argumentIndex))
                }
            }
            val port = value.optInt("port", 0)
            require(port in 1..65535) { "Runtime node $index has invalid port" }
            val rawStartupFailurePatterns =
                value.optJSONArray("startupFailurePatterns") ?: JSONArray()
            require(rawStartupFailurePatterns.length() <= MAX_STARTUP_FAILURE_PATTERNS) {
                "Runtime node $index has too many startup failure patterns"
            }
            val startupFailurePatterns = buildList {
                for (patternIndex in 0 until rawStartupFailurePatterns.length()) {
                    val pattern = rawStartupFailurePatterns.getString(patternIndex).trim()
                    require(
                        pattern.isNotEmpty() &&
                            pattern.length <= MAX_STARTUP_FAILURE_PATTERN_LENGTH,
                    ) {
                        "Runtime node $index has an invalid startup failure pattern"
                    }
                    add(pattern)
                }
            }
            return RuntimeNodeSpec(
                nodeId = requiredString("nodeId"),
                type = requiredString("type"),
                name = requiredString("name"),
                host = requiredString("host"),
                port = port,
                executablePath = requiredString("executablePath"),
                workingDirectory = requiredString("workingDirectory"),
                arguments = arguments,
                revision = requiredString("revision"),
                connectivityCheck = RuntimeNodeConnectivityCheck.fromJson(
                    value.optJSONObject("connectivityCheck"),
                ),
                resolverFile = RuntimeNodeResolverFile.fromJson(
                    value.optJSONObject("resolverFile"),
                ),
                startupFailurePatterns = startupFailurePatterns,
            )
        }
    }
}

object RuntimeNodeClientRegistry {
    private val clients = AtomicInteger(0)

    val hasClients: Boolean get() = clients.get() > 0

    fun attach() {
        clients.incrementAndGet()
    }

    fun detach() {
        clients.updateAndGet { current -> if (current > 0) current - 1 else 0 }
    }

    fun clear() {
        clients.set(0)
    }
}

internal suspend fun selectRuntimeNodeProbeIndex(
    nodeCount: Int,
    concurrency: Int,
    probe: suspend (Int) -> Boolean,
): Int = coroutineScope {
    require(nodeCount > 0) { "Runtime-node probe batch must not be empty" }
    require(concurrency > 0) { "Runtime-node probe concurrency must be positive" }
    val workerCount = minOf(concurrency, nodeCount)
    val nextIndex = AtomicInteger(0)
    val remainingWorkers = AtomicInteger(workerCount)
    val selected = CompletableDeferred<Int?>()
    val workers = List(workerCount) {
        launch {
            try {
                while (isActive && !selected.isCompleted) {
                    val index = nextIndex.getAndIncrement()
                    if (index >= nodeCount) break
                    if (probe(index)) {
                        selected.complete(index)
                        break
                    }
                }
            } finally {
                if (remainingWorkers.decrementAndGet() == 0) {
                    selected.complete(null)
                }
            }
        }
    }
    val selectedIndex = selected.await()
    if (selectedIndex != null) {
        workers.forEach { it.cancel() }
    }
    workers.joinAll()
    selectedIndex ?: -1
}

object RuntimeNodeProcessManager {
    private class OutputBuffer {
        private val lines = ArrayDeque<String>()
        private var length = 0

        @Synchronized
        fun add(line: String) {
            val boundedLine = line.takeLast(MAX_OUTPUT_LENGTH)
            lines.addLast(boundedLine)
            length += boundedLine.length
            while (lines.size > MAX_OUTPUT_LINES || length > MAX_OUTPUT_LENGTH) {
                length -= lines.removeFirst().length
            }
        }

        @Synchronized
        fun snapshot(): String = lines.joinToString("\n")

        @Synchronized
        fun firstLineContaining(patterns: List<String>): String? =
            lines.firstOrNull { line -> patterns.any(line::contains) }
    }

    private data class RunningNode(
        val process: Process,
        val startTimeMillis: Long,
        val spec: RuntimeNodeSpec,
        val output: OutputBuffer,
        val logJob: Job?,
    )

    private data class NodeOutcome(
        val spec: RuntimeNodeSpec,
        val ready: Boolean,
        val reused: Boolean,
        val message: String = "",
    )

    private data class SystemDnsPassResult(
        val incomplete: Boolean,
        val epoch: Long,
    )

    // Last DNS servers seen on the physical network. Held here, not in Dart,
    // so cold start and DNS changes work with no Flutter process running.
    @Volatile private var latestSystemDns: List<String>? = null
    @Volatile private var lastAppliedSystemDns: List<String>? = null

    /**
     * DNS servers to render resolver files with. Falls back to reading the
     * platform directly, so a cold start that runs before any network observer
     * is installed still produces a usable resolver list.
     */
    private fun currentSystemDns(): List<String> {
        val cached = latestSystemDns
        if (cached != null) return cached
        val resolved = SystemDnsReader.read()
        latestSystemDns = resolved
        return resolved
    }

    private val planLock = Mutex()
    private val planTransitionLock = Mutex()
    private val nodeLocks = ConcurrentHashMap<String, Mutex>()
    private val runningNodes = ConcurrentHashMap<String, RunningNode>()
    private val activeBatchProbeJobs = mutableSetOf<Job>()
    private val readyNodeIds = ConcurrentHashMap.newKeySet<String>()

    // Why a node refused to launch, keyed by node id. `start` only reports a
    // long, so without this the reason ("the network advertises no DNS", "the
    // binary is missing") stayed in the log and the user was shown the generic
    // "did not start".
    private val startFailures = ConcurrentHashMap<String, String>()

    // DNS passes currently running, so a plan transition can preempt them
    // instead of queueing behind a node restart.
    private val systemDnsPassJobs = ConcurrentHashMap.newKeySet<Job>()

    // Nodes this manager stopped for a DNS change that have not come back yet.
    // A later pass renders their resolver file to the same bytes and would skip
    // them as UNCHANGED, so the outstanding work has to be remembered here for
    // the retry to mean anything.
    private val pendingSystemDnsRestarts = ConcurrentHashMap.newKeySet<String>()

    // Reset failures have to survive independently of restart failures. A
    // sleeping reserve node is not restarted, but an UNCHANGED render on the
    // next pass must still retry the cache reset it previously failed.
    private val pendingSystemDnsResets = ConcurrentHashMap.newKeySet<String>()

    // One retry loop per DNS list. Duplicate Android callbacks may all observe
    // the same incomplete update; keeping every loop reachable avoids both
    // duplicate work and jobs that a plan transition can no longer cancel.
    private val systemDnsRetryJobs = ConcurrentHashMap<List<String>, Job>()
    @Volatile private var systemDnsWorkEpoch = 0L
    private var activePlan = linkedMapOf<String, RuntimeNodeSpec>()
        set(value) {
            field = value
            // Kept in lockstep with the plan itself so `updateSystemDns` can
            // tell "nothing here cares about system DNS" without the plan lock.
            hasSystemDnsDependents = value.values.any {
                it.resolverFile?.dependsOnSystemDns == true
            }
        }

    // Mirror of the plan above, readable without a lock. Written only under
    // `planLock`, by the setter.
    @Volatile private var hasSystemDnsDependents = false
    private var acceptingBatchProbes = true
    @Volatile private var generation = 0L
    private var optionalCheckJob: Job? = null
    @Volatile private var lastStateJson = stateJson(0L, "idle", emptyList())

    suspend fun applyPlan(planJson: String): String {
        // A DNS-triggered pass holds the plan lock for as long as the nodes it
        // restarts need. Applying a profile is a direct user action and must
        // not queue behind an environment event, so the pass is preempted here:
        // it stops whatever it was bringing up and re-schedules itself, and the
        // plan below starts those nodes anyway.
        cancelSystemDnsWork()
        return applyPlanLocked(planJson)
    }

    private suspend fun applyPlanLocked(planJson: String): String =
        withBatchProbesStopped {
        val target = parsePlan(planJson)
        val previousPlan = activePlan
        val previousReady = readyNodeIds.toSet()
        val reusable = target.filter { (nodeId, spec) ->
            previousPlan[nodeId] == spec &&
                nodeId in previousReady &&
                nodeId !in pendingSystemDnsRestarts &&
                nodeId !in pendingSystemDnsResets &&
                readStartTime(nodeId) > 0L
        }.keys

        if (target == previousPlan && reusable.size == target.size) {
            lastStateJson = stateJson(
                generation,
                if (target.isEmpty()) "idle" else "ready",
                target.values.map { NodeOutcome(it, ready = true, reused = true) },
            )
            return@withBatchProbesStopped lastStateJson
        }

        generation += 1L
        val currentGeneration = generation
        optionalCheckJob?.cancelAndJoin()
        optionalCheckJob = null

        val replacedOrRemoved = previousPlan.values.filter { previous ->
            target[previous.nodeId] != previous
        }
        stopSpecs(replacedOrRemoved)
        replacedOrRemoved.forEach { readyNodeIds.remove(it.nodeId) }

        val outcomes = coroutineScope {
            target.values.map { spec ->
                async {
                    if (spec.nodeId in reusable) {
                        NodeOutcome(spec, ready = true, reused = true)
                    } else {
                        prepareNode(spec)
                    }
                }
            }.awaitAll()
        }

        val failure = outcomes.firstOrNull { !it.ready }
        if (failure != null) {
            stopAllProcesses()
            activePlan = linkedMapOf()
            readyNodeIds.clear()
            pendingSystemDnsRestarts.clear()
            pendingSystemDnsResets.clear()
            lastStateJson = stateJson(
                currentGeneration,
                "failed",
                outcomes,
                failure.message.ifBlank { "Runtime node `${failure.spec.nodeId}` is not ready" },
            )
            return@withBatchProbesStopped lastStateJson
        }

        activePlan = LinkedHashMap(target)
        readyNodeIds.clear()
        readyNodeIds.addAll(target.keys)
        // This transition supersedes anything a DNS pass left unfinished.
        pendingSystemDnsRestarts.clear()
        pendingSystemDnsResets.clear()
        lastStateJson = stateJson(
            currentGeneration,
            if (target.isEmpty()) "idle" else "ready",
            outcomes,
        )
        launchOptionalChecks(currentGeneration, target.values.toList())
        lastStateJson = stateJson(
            currentGeneration,
            if (target.isEmpty()) "idle" else "ready",
            outcomes,
        )
        lastStateJson
    }

    suspend fun probeNode(nodeJson: String): Boolean = planLock.withLock {
        check(acceptingBatchProbes) { "Runtime-node plan transition is in progress" }
        val spec = RuntimeNodeSpec.fromJson(JSONObject(nodeJson), 0)
        require(
            !activePlan.containsKey(spec.nodeId) &&
                !runningNodes.containsKey(spec.nodeId),
        ) {
            "Runtime-node probe `${spec.nodeId}` conflicts with an active node"
        }
        require(spec.connectivityCheck.required && spec.connectivityCheck.urls.isNotEmpty()) {
            "Runtime-node probe `${spec.nodeId}` requires a connectivity check"
        }
        try {
            prepareNode(spec).ready
        } finally {
            stop(spec.nodeId)
        }
    }

    suspend fun probeNodes(requestJson: String): Int {
        val request = JSONObject(requestJson)
        val values = request.optJSONArray("nodes") ?: JSONArray()
        val concurrency = request.optInt("concurrency", 1)
        require(concurrency in 1..MAX_PROBE_CONCURRENCY) {
            "Runtime-node probe concurrency must be between 1 and $MAX_PROBE_CONCURRENCY"
        }
        require(values.length() in 1..MAX_PROBE_NODES) {
            "Runtime-node probe batch must contain between 1 and $MAX_PROBE_NODES nodes"
        }
        val probeJob = checkNotNull(currentCoroutineContext()[Job])
        val specs = planLock.withLock {
            check(acceptingBatchProbes) { "Runtime-node plan transition is in progress" }
            try {
                buildList {
                    val nodeIds = mutableSetOf<String>()
                    for (index in 0 until values.length()) {
                        val spec = RuntimeNodeSpec.fromJson(values.getJSONObject(index), index)
                        require(nodeIds.add(spec.nodeId)) {
                            "Runtime-node probe `${spec.nodeId}` is duplicated"
                        }
                        require(
                            !activePlan.containsKey(spec.nodeId) &&
                                !runningNodes.containsKey(spec.nodeId),
                        ) {
                            "Runtime-node probe `${spec.nodeId}` conflicts with an active node"
                        }
                        require(spec.connectivityCheck.required && spec.connectivityCheck.urls.isNotEmpty()) {
                            "Runtime-node probe `${spec.nodeId}` requires a connectivity check"
                        }
                        add(spec)
                    }
                }.also {
                    activeBatchProbeJobs.add(probeJob)
                }
            } catch (error: Throwable) {
                activeBatchProbeJobs.remove(probeJob)
                throw error
            }
        }

        return try {
            selectRuntimeNodeProbeIndex(specs.size, concurrency) { index ->
                probeNodeOnce(specs[index])
            }
        } finally {
            withContext(NonCancellable) {
                planLock.withLock { activeBatchProbeJobs.remove(probeJob) }
            }
        }
    }

    fun readPlanState(): String = runCatching {
        JSONObject(lastStateJson)
            .put("optionalCheckActive", optionalCheckJob?.isActive == true)
            .toString()
    }.getOrDefault(lastStateJson)

    /**
     * Applies a new physical-network DNS list.
     *
     * Rewrites the resolver file of every node that declared a dependency on
     * system DNS, drops the working caches those nodes bound to the old list,
     * and restarts only the ones whose list actually changed.
     *
     * Two properties of this path are deliberate.
     *
     * *It never makes a profile apply wait.* The work runs under the plan lock,
     * because rendering, cache resets and restarts have to be serialised
     * against [applyPlan] — anything looser races. Rather than shrink the
     * restart budget until holding the lock is cheap (which would make a slow
     * but legitimate restart impossible), the pass is preemptible: [applyPlan]
     * and [stopAll] cancel it before they queue for the lock, a cancelled
     * restart stops the node it was bringing up, and the transition that
     * preempted it starts that node itself. [DNS_UPDATE_BUDGET_MILLIS] bounds
     * the pass for every caller that does not preempt.
     *
     * *Its failure semantics differ from [applyPlan], on purpose.* `applyPlan`
     * owns the plan: a node that cannot start there means the profile the user
     * just asked for is not runnable, so every process is stopped and the plan
     * is cleared. A DNS change is an environment event arriving at a plan that
     * is already running; tearing down healthy nodes because one dependent
     * failed to come back would turn a transient network hiccup into a full
     * outage. The plan therefore stays active, the failing node is reported
     * through the plan state, and [scheduleSystemDnsRetry] gives it further
     * attempts without waiting for the OS to send another callback.
     */
    suspend fun updateSystemDns(dnsServers: List<String>) {
        val normalized = SystemDnsReader.sanitize(dnsServers)
        latestSystemDns = normalized

        // Callbacks that change nothing are answered from volatile state alone.
        // `runSystemDnsPass` takes the plan transition lock and cancels every
        // batch probe in flight *before* `applySystemDns` gets to make the same
        // check, so a redundant DNS event used to abort a running auto-probe.
        // The authoritative checks stay where they were: this is an
        // optimisation, and losing the race only costs one needless pass.
        if (
            normalized == lastAppliedSystemDns &&
            pendingSystemDnsRestarts.isEmpty() &&
            pendingSystemDnsResets.isEmpty()
        ) {
            return
        }
        if (!hasSystemDnsDependents) {
            lastAppliedSystemDns = normalized
            pendingSystemDnsRestarts.clear()
            pendingSystemDnsResets.clear()
            return
        }

        val pass = try {
            runSystemDnsPass(normalized)
        } catch (cancellation: CancellationException) {
            // A plan transition preempted this pass and now owns every node it
            // left behind. It also invalidated the pass epoch, so no old work may
            // be re-created after cancelSystemDnsWork returned.
            throw cancellation
        }
        if (pass.incomplete) scheduleSystemDnsRetry(normalized, pass.epoch)
    }

    private suspend fun runSystemDnsPass(normalized: List<String>): SystemDnsPassResult {
        val job = currentCoroutineContext()[Job]
        if (job != null) systemDnsPassJobs.add(job)
        return try {
            withBatchProbesStopped {
                SystemDnsPassResult(
                    incomplete = applySystemDns(normalized),
                    // Read under the plan-transition lock. A pass that queued
                    // behind a completed transition belongs to the new epoch;
                    // one that finished before it must not schedule stale work.
                    epoch = systemDnsWorkEpoch,
                )
            }
        } finally {
            if (job != null) systemDnsPassJobs.remove(job)
        }
    }

    /** Returns whether work is left over and a retry is worth scheduling. */
    private suspend fun applySystemDns(normalized: List<String>): Boolean {
        if (
            normalized == lastAppliedSystemDns &&
            pendingSystemDnsRestarts.isEmpty() &&
            pendingSystemDnsResets.isEmpty()
        ) {
            return false
        }

        val dependents = activePlan.values.filter {
            it.resolverFile?.dependsOnSystemDns == true
        }
        if (dependents.isEmpty()) {
            lastAppliedSystemDns = normalized
            pendingSystemDnsRestarts.clear()
            pendingSystemDnsResets.clear()
            return false
        }
        generation += 1L
        val currentGeneration = generation
        optionalCheckJob?.cancelAndJoin()
        optionalCheckJob = null

        // Only the nodes this pass actually worked on decide its status.
        val touched = linkedMapOf<String, NodeOutcome>()
        val deadline = SystemClock.elapsedRealtime() + DNS_UPDATE_BUDGET_MILLIS

        for (spec in dependents) {
            val resolverFile = spec.resolverFile ?: continue
            val runtimeDir = File(spec.workingDirectory)
            val restartPending = pendingSystemDnsRestarts.contains(spec.nodeId)
            val resetPending = pendingSystemDnsResets.contains(spec.nodeId)
            val wasRunning = restartPending || readStartTime(spec.nodeId) > 0L
            val renderResult = withContext(Dispatchers.IO) {
                RuntimeNodeResolverFileWriter.render(
                    workingDirectory = runtimeDir,
                    spec = resolverFile,
                    systemDns = normalized,
                )
            }
            when (renderResult) {
                RuntimeNodeResolverFileRenderResult.UNCHANGED -> {
                    // Nothing to write. Fall through only when an earlier pass
                    // left this node down: then the outstanding work is the
                    // restart or reset, and no later render will ever report
                    // CHANGED.
                    if (!restartPending && !resetPending) continue
                }

                RuntimeNodeResolverFileRenderResult.CHANGED -> {
                    pendingSystemDnsResets.add(spec.nodeId)
                }

                else -> {
                    val message = resolverRenderFailureMessage(renderResult, spec.nodeId)
                    GlobalState.log(message)
                    stop(spec.nodeId)
                    readyNodeIds.remove(spec.nodeId)
                    if (wasRunning) pendingSystemDnsRestarts.add(spec.nodeId)
                    touched[spec.nodeId] = NodeOutcome(
                        spec = spec,
                        ready = false,
                        reused = false,
                        message = message,
                    )
                    continue
                }
            }

            if (wasRunning) {
                stop(spec.nodeId)
                readyNodeIds.remove(spec.nodeId)
                pendingSystemDnsRestarts.add(spec.nodeId)
            }

            val reset = withContext(Dispatchers.IO) {
                RuntimeNodeResolverFileWriter.resetDeclaredPaths(runtimeDir, resolverFile)
            }
            if (!reset) {
                val message =
                    "Could not reset resolver-dependent state for runtime node `${spec.nodeId}`"
                GlobalState.log(message)
                touched[spec.nodeId] = NodeOutcome(
                    spec = spec,
                    ready = false,
                    reused = false,
                    message = message,
                )
                continue
            }
            pendingSystemDnsResets.remove(spec.nodeId)

            // Only nodes that are actually running are restarted; a sleeping
            // reserve node picks the new list up when it is next started.
            if (!wasRunning) continue

            val budget = deadline - SystemClock.elapsedRealtime()
            if (budget < DNS_RESTART_MIN_BUDGET_MILLIS) {
                // Out of budget rather than broken: hand the rest to the retry
                // instead of holding the plan lock for another startup timeout.
                val message = "Runtime node `${spec.nodeId}` was not restarted after a " +
                    "DNS change: this update ran out of its time budget"
                GlobalState.log(message)
                touched[spec.nodeId] = NodeOutcome(
                    spec = spec,
                    ready = false,
                    reused = false,
                    message = message,
                )
                continue
            }

            GlobalState.log("Restarting runtime node `${spec.nodeId}` after a system DNS change")
            val outcome = try {
                prepareNode(
                    spec,
                    startupTimeoutMillis =
                        minOf(spec.connectivityCheck.startupTimeoutMillis, budget),
                )
            } catch (cancellation: CancellationException) {
                // Preempted mid-restart: leave nothing half-started behind. The
                // node stays in pendingSystemDnsRestarts, and the transition
                // that preempted this pass owns it now.
                withContext(NonCancellable) {
                    stop(spec.nodeId)
                    readyNodeIds.remove(spec.nodeId)
                }
                throw cancellation
            }
            if (outcome.ready) {
                readyNodeIds.add(spec.nodeId)
                pendingSystemDnsRestarts.remove(spec.nodeId)
            } else {
                readyNodeIds.remove(spec.nodeId)
                GlobalState.log(
                    "Runtime node `${spec.nodeId}` failed to restart after a DNS change: " +
                        outcome.message,
                )
            }
            touched[spec.nodeId] = outcome
        }

        // The reported node list still covers the whole plan, so a node that was
        // already down stays visible as such. The plan *status*, however, is
        // decided by the nodes this pass touched: an unrelated failure must not
        // turn a successful DNS update into a failed plan, nor keep the optional
        // checks of the nodes that did come back from running.
        val outcomes = activePlan.values.map { spec ->
            touched[spec.nodeId] ?: untouchedOutcome(spec)
        }
        val failure = touched.values.firstOrNull { !it.ready }
        lastStateJson = stateJson(
            currentGeneration,
            if (failure == null) "ready" else "failed",
            outcomes,
            failure?.message.orEmpty(),
        )
        if (failure == null) {
            lastAppliedSystemDns = normalized
            launchOptionalChecks(currentGeneration, activePlan.values.toList())
        }
        return failure != null
    }

    /** Plan entry for a node this DNS pass did not have to touch. */
    private fun untouchedOutcome(spec: RuntimeNodeSpec): NodeOutcome {
        val ready = spec.nodeId in readyNodeIds && readStartTime(spec.nodeId) > 0L
        return NodeOutcome(
            spec = spec,
            ready = ready,
            reused = ready,
            message = if (ready) {
                ""
            } else {
                readLastError(spec.nodeId).ifBlank {
                    "Runtime node `${spec.nodeId}` is not running"
                }
            },
        )
    }

    private fun resolverRenderFailureMessage(
        result: RuntimeNodeResolverFileRenderResult,
        nodeId: String,
    ): String = when (result) {
        RuntimeNodeResolverFileRenderResult.SYSTEM_DNS_UNAVAILABLE ->
            "Runtime node `$nodeId` has no DNS servers to work with: the current " +
                "network advertises none and the node declares no others"

        else -> "Could not render the resolver file for runtime node `$nodeId`"
    }

    /**
     * Finishes an incomplete DNS update without waiting for the OS to send
     * another network callback.
     *
     * A sleeping attempt is never cancelled by a newer list — it notices the
     * mismatch itself and exits — because cancelling one that had already
     * started its pass is the only way this could interfere with a plan
     * transition.
     */
    @Synchronized
    private fun scheduleSystemDnsRetry(target: List<String>, expectedEpoch: Long) {
        if (expectedEpoch != systemDnsWorkEpoch) return
        val retryTarget = target.toList()
        if (systemDnsRetryJobs[retryTarget]?.isActive == true) return

        val retryJob = GlobalState.scope.launch(start = CoroutineStart.LAZY) {
            var attempt = 1
            while (attempt <= MAX_SYSTEM_DNS_RETRIES) {
                delay(SYSTEM_DNS_RETRY_DELAY_MILLIS * attempt)
                // A newer list has a pass and a retry of its own.
                if (
                    systemDnsWorkEpoch != expectedEpoch ||
                    latestSystemDns != retryTarget
                ) {
                    return@launch
                }
                GlobalState.log(
                    "Retrying the runtime-node DNS update (attempt $attempt of " +
                        "$MAX_SYSTEM_DNS_RETRIES)",
                )
                val pass = try {
                    runSystemDnsPass(retryTarget)
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (error: Throwable) {
                    GlobalState.log("runtime-node DNS retry failed: ${error.message}")
                    SystemDnsPassResult(incomplete = true, epoch = expectedEpoch)
                }
                if (pass.epoch != expectedEpoch) return@launch
                if (!pass.incomplete) return@launch
                attempt += 1
            }
            GlobalState.log(
                "Gave up on the runtime-node DNS update after $MAX_SYSTEM_DNS_RETRIES retries",
            )
        }
        systemDnsRetryJobs[retryTarget] = retryJob
        retryJob.invokeOnCompletion {
            systemDnsRetryJobs.remove(retryTarget, retryJob)
        }
        retryJob.start()
    }

    /**
     * Stops DNS work before a plan transition takes the lock.
     *
     * Cancel only, never join: the caller is about to take the very lock a pass
     * may be holding, so waiting for it here would deadlock.
     */
    @Synchronized
    private fun cancelSystemDnsWork() {
        systemDnsWorkEpoch += 1L
        systemDnsRetryJobs.values.forEach { it.cancel() }
        systemDnsRetryJobs.clear()
        systemDnsPassJobs.forEach { it.cancel() }
    }

    suspend fun stopAll() {
        cancelSystemDnsWork()
        withBatchProbesStopped {
            optionalCheckJob?.cancelAndJoin()
            optionalCheckJob = null
            stopAllProcesses()
            activePlan = linkedMapOf()
            readyNodeIds.clear()
            pendingSystemDnsRestarts.clear()
            pendingSystemDnsResets.clear()
            generation += 1L
            lastStateJson = stateJson(generation, "idle", emptyList())
        }
    }

    private suspend fun <T> withBatchProbesStopped(block: suspend () -> T): T =
        planTransitionLock.withLock {
            val jobs = planLock.withLock {
                acceptingBatchProbes = false
                activeBatchProbeJobs.forEach { it.cancel() }
                activeBatchProbeJobs.toList()
            }
            try {
                withContext(NonCancellable) { jobs.joinAll() }
                currentCoroutineContext().ensureActive()
                planLock.withLock { block() }
            } finally {
                withContext(NonCancellable) {
                    planLock.withLock {
                        acceptingBatchProbes = true
                    }
                }
            }
        }

    suspend fun stopIfIdle(vpnActive: Boolean) {
        if (!vpnActive && !RuntimeNodeClientRegistry.hasClients) {
            stopAll()
        }
    }

    fun readStartTime(nodeId: String): Long {
        val running = runningNodes[nodeId] ?: return 0L
        return if (running.process.isAlive && running.startTimeMillis > 0L) {
            running.startTimeMillis
        } else {
            0L
        }
    }

    fun readLastError(nodeId: String): String {
        val running = runningNodes[nodeId] ?: return ""
        if (running.process.isAlive) return ""
        val exitCode = runCatching { running.process.exitValue() }.getOrNull()
        val output = running.output.snapshot().trim()
        val prefix = if (exitCode == null) {
            "runtime node exited"
        } else {
            "runtime node exited with code $exitCode"
        }
        return if (output.isEmpty()) prefix else "$prefix: $output"
    }

    private fun parsePlan(planJson: String): LinkedHashMap<String, RuntimeNodeSpec> {
        val root = JSONObject(planJson)
        val rawNodes = root.optJSONArray("nodes") ?: JSONArray()
        val result = linkedMapOf<String, RuntimeNodeSpec>()
        for (index in 0 until rawNodes.length()) {
            val spec = RuntimeNodeSpec.fromJson(rawNodes.getJSONObject(index), index)
            require(result.put(spec.nodeId, spec) == null) {
                "Runtime node `${spec.nodeId}` is duplicated"
            }
        }
        return result
    }

    /**
     * Starts [spec] and waits until it is usable.
     *
     * [startupTimeoutMillis] defaults to what the node declared; callers that
     * hold a shared lock pass a smaller budget instead of copying the spec,
     * because a copied spec would no longer match the running process and would
     * cost the node a pointless restart on the next plan.
     */
    private suspend fun prepareNode(
        spec: RuntimeNodeSpec,
        startupTimeoutMillis: Long = spec.connectivityCheck.startupTimeoutMillis,
    ): NodeOutcome {
        return runCatching {
            val startedAt = start(spec)
            check(startedAt > 0L) {
                startFailures.remove(spec.nodeId)
                    ?: "Runtime node `${spec.nodeId}` did not start"
            }
            val deadline = SystemClock.elapsedRealtime() + startupTimeoutMillis
            waitForListener(spec, deadline)
            check(readStartTime(spec.nodeId) > 0L) {
                "Runtime node `${spec.nodeId}` exited after opening its local listener"
            }
            val check = spec.connectivityCheck
            if (check.required && check.urls.isNotEmpty()) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                check(remaining > 0L) {
                    "Runtime node `${spec.nodeId}` exhausted its startup timeout"
                }
                val passed = RuntimeNodeConnectivityChecker.checkUntilDeadline(
                    nodeId = spec.nodeId,
                    host = spec.host,
                    port = spec.port,
                    config = check.copy(startupTimeoutMillis = remaining),
                )
                check(passed) {
                    "Runtime node `${spec.nodeId}` failed its required connectivity check"
                }
            }
            NodeOutcome(spec, ready = true, reused = false)
        }.getOrElse { error ->
            // Cancellation is not a node failure: something with a stronger
            // claim on the plan lock preempted us and has to be able to unwind.
            if (error is CancellationException) throw error
            NodeOutcome(
                spec,
                ready = false,
                reused = false,
                message = error.message ?: error.toString(),
            )
        }
    }

    private suspend fun probeNodeOnce(spec: RuntimeNodeSpec): Boolean {
        return try {
            val startedAt = start(spec)
            if (startedAt <= 0L) return false
            val deadline =
                SystemClock.elapsedRealtime() + spec.connectivityCheck.startupTimeoutMillis
            waitForListener(spec, deadline)
            if (readStartTime(spec.nodeId) <= 0L) return false
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0L) return false
            withTimeoutOrNull(remaining) {
                RuntimeNodeConnectivityChecker.checkOnce(
                    host = spec.host,
                    port = spec.port,
                    config = spec.connectivityCheck,
                )
            } == true && readStartTime(spec.nodeId) > 0L
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            false
        } finally {
            withContext(NonCancellable) { stop(spec.nodeId) }
        }
    }

    private fun launchOptionalChecks(currentGeneration: Long, specs: List<RuntimeNodeSpec>) {
        val optional = specs.filter {
            !it.connectivityCheck.required && it.connectivityCheck.urls.isNotEmpty()
        }
        if (optional.isEmpty()) return
        optionalCheckJob = GlobalState.scope.launch {
            coroutineScope {
                optional.map { spec ->
                    async {
                        val passed = RuntimeNodeConnectivityChecker.checkUntilDeadline(
                            nodeId = spec.nodeId,
                            host = spec.host,
                            port = spec.port,
                            config = spec.connectivityCheck,
                        )
                        if (!passed && generation == currentGeneration) {
                            GlobalState.log(
                                "Runtime node `${spec.nodeId}` failed its optional connectivity check",
                            )
                        }
                    }
                }.awaitAll()
            }
        }
    }

    private suspend fun waitForListener(spec: RuntimeNodeSpec, deadline: Long) {
        withContext(Dispatchers.IO) {
            // Most nodes open their port within a few tens of milliseconds, and
            // a fixed interval made every one of them look that much slower.
            // The poll starts tight and backs off to the old fixed interval, so
            // a node that legitimately takes minutes still costs the same few
            // probes per second it did before.
            var retryMillis = LISTENER_MIN_RETRY_MILLIS
            while (true) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                check(remaining > 0L) {
                    "Timed out waiting for runtime node listener on ${spec.host}:${spec.port}"
                }
                val connected = runCatching {
                    Socket().use { socket ->
                        socket.connect(
                            InetSocketAddress(spec.host, spec.port),
                            minOf(LISTENER_CONNECT_TIMEOUT_MILLIS, remaining).toInt(),
                        )
                    }
                }.isSuccess
                if (connected) return@withContext
                val startupFailure = runningNodes[spec.nodeId]
                    ?.output
                    ?.firstLineContaining(spec.startupFailurePatterns)
                if (startupFailure != null) {
                    error(
                        "Runtime node `${spec.nodeId}` reported a startup failure: " +
                            startupFailure,
                    )
                }
                if (readStartTime(spec.nodeId) <= 0L) {
                    val lastError = readLastError(spec.nodeId)
                    error(
                        if (lastError.isBlank()) {
                            "Runtime node `${spec.nodeId}` exited before opening its local listener"
                        } else {
                            "Runtime node `${spec.nodeId}` failed: $lastError"
                        },
                    )
                }
                delay(minOf(retryMillis, remaining))
                retryMillis = minOf(retryMillis * 2, LISTENER_MAX_RETRY_MILLIS)
            }
        }
    }

    /** Records why a node refused to launch and reports "did not start". */
    private fun failStart(nodeId: String, message: String): Long {
        startFailures[nodeId] = message
        GlobalState.log(message)
        return 0L
    }

    private suspend fun start(spec: RuntimeNodeSpec): Long {
        val lock = nodeLocks.getOrPut(spec.nodeId) { Mutex() }
        return lock.withLock {
            withContext(Dispatchers.IO) {
                startFailures.remove(spec.nodeId)
                val running = runningNodes[spec.nodeId]
                if (
                    running?.process?.isAlive == true &&
                    running.spec == spec &&
                    spec.nodeId !in pendingSystemDnsRestarts &&
                    spec.nodeId !in pendingSystemDnsResets
                ) {
                    return@withContext running.startTimeMillis
                }
                if (running != null) stopInternal(spec.nodeId)

                val executable = File(spec.executablePath)
                if (!executable.exists()) {
                    return@withContext failStart(
                        spec.nodeId,
                        "runtime node binary is missing: ${spec.executablePath}",
                    )
                }
                if (executable.canWrite()) {
                    executable.setExecutable(true, true)
                } else if (!executable.canExecute()) {
                    return@withContext failStart(
                        spec.nodeId,
                        "runtime node binary is not executable: ${spec.executablePath}",
                    )
                }

                val runtimeDir = File(spec.workingDirectory)
                if (!runtimeDir.exists()) runtimeDir.mkdirs()
                // The generated resolver list is rebuilt from its template on
                // every launch so a node started at cold start picks up the
                // system DNS observed since the plan was written.
                spec.resolverFile?.let { resolverFile ->
                    val renderResult = RuntimeNodeResolverFileWriter.render(
                        workingDirectory = runtimeDir,
                        spec = resolverFile,
                        systemDns = currentSystemDns(),
                    )
                    if (
                        renderResult == RuntimeNodeResolverFileRenderResult.FAILED ||
                        renderResult ==
                        RuntimeNodeResolverFileRenderResult.SYSTEM_DNS_UNAVAILABLE
                    ) {
                        return@withContext failStart(
                            spec.nodeId,
                            resolverRenderFailureMessage(renderResult, spec.nodeId),
                        )
                    }
                    if (
                        (
                            renderResult == RuntimeNodeResolverFileRenderResult.CHANGED ||
                                pendingSystemDnsResets.contains(spec.nodeId)
                        ) &&
                        !RuntimeNodeResolverFileWriter.resetDeclaredPaths(
                            runtimeDir,
                            resolverFile,
                        )
                    ) {
                        return@withContext failStart(
                            spec.nodeId,
                            "Could not reset resolver-dependent state for runtime node " +
                                "`${spec.nodeId}`",
                        )
                    }
                    pendingSystemDnsResets.remove(spec.nodeId)
                }
                val process = try {
                    ProcessBuilder(listOf(spec.executablePath) + spec.arguments)
                        .directory(runtimeDir)
                        .redirectErrorStream(true)
                        .start()
                } catch (error: Exception) {
                    return@withContext failStart(
                        spec.nodeId,
                        "Failed to start runtime node `${spec.nodeId}`: ${error.message}",
                    )
                }

                val startedAt = System.currentTimeMillis()
                val output = OutputBuffer()
                val logJob = GlobalState.scope.launch(Dispatchers.IO) {
                    runCatching {
                        BoundedUtf8LineReader(process.inputStream).use { reader ->
                            reader.forEachLine { line ->
                                if (line.isNotBlank()) {
                                    output.add(line)
                                    DiagnosticLog.runtimeNode(spec.type, line)
                                }
                            }
                        }
                    }.onFailure {
                        if (process.isAlive) {
                            GlobalState.log(
                                "runtime node `${spec.nodeId}` log reader failed: ${it.message}",
                            )
                        }
                    }
                }
                runningNodes[spec.nodeId] = RunningNode(
                    process = process,
                    startTimeMillis = startedAt,
                    spec = spec,
                    output = output,
                    logJob = logJob,
                )
                startedAt
            }
        }
    }

    private suspend fun stopSpecs(specs: Collection<RuntimeNodeSpec>) = coroutineScope {
        specs.map { spec -> async { stop(spec.nodeId) } }.awaitAll()
    }

    private suspend fun stopAllProcesses() {
        val specs = runningNodes.values.map { it.spec }
        stopSpecs(specs)
    }

    private suspend fun stop(nodeId: String) {
        val lock = nodeLocks.getOrPut(nodeId) { Mutex() }
        lock.withLock {
            withContext(Dispatchers.IO) { stopInternal(nodeId) }
        }
        nodeLocks.remove(nodeId, lock)
    }

    private suspend fun stopInternal(nodeId: String) {
        val previous = runningNodes.remove(nodeId) ?: return
        var needsEmergencySweep = false
        runCatching {
            previous.process.destroy()
            if (!previous.process.waitFor(SOFT_STOP_MILLIS, TimeUnit.MILLISECONDS)) {
                previous.process.destroyForcibly()
                previous.process.waitFor(FORCE_STOP_MILLIS, TimeUnit.MILLISECONDS)
            }
            needsEmergencySweep = previous.process.isAlive
        }.onFailure {
            needsEmergencySweep = true
            GlobalState.log("Failed to stop runtime node `$nodeId`: ${it.message}")
        }

        if (needsEmergencySweep) {
            killMatchingRuntimeProcesses(previous.spec)
        }
        runCatching { previous.process.outputStream.close() }
        runCatching { previous.process.inputStream.close() }
        runCatching { previous.process.errorStream.close() }
        previous.logJob?.cancelAndJoin()
        readyNodeIds.remove(nodeId)
    }

    private fun killMatchingRuntimeProcesses(spec: RuntimeNodeSpec) {
        val expected = listOf(spec.executablePath) + spec.arguments
        val selfPid = android.os.Process.myPid()
        val entries = File("/proc").listFiles() ?: return
        for (entry in entries) {
            val pid = entry.name.toIntOrNull() ?: continue
            if (pid == selfPid) continue
            val cmdline = readProcessCmdline(pid) ?: continue
            if (cmdline != expected) continue
            runCatching {
                android.os.Process.killProcess(pid)
                waitForProcessExit(pid)
            }.onFailure {
                GlobalState.log(
                    "Emergency cleanup failed for runtime node `${spec.nodeId}` process $pid: ${it.message}",
                )
            }
        }
    }

    private fun readProcessCmdline(pid: Int): List<String>? = runCatching {
        File("/proc/$pid/cmdline")
            .readBytes()
            .toString(Charsets.UTF_8)
            .split('\u0000')
            .filter { it.isNotEmpty() }
    }.getOrNull()

    private fun waitForProcessExit(pid: Int) {
        val procPath = File("/proc/$pid")
        val deadline = System.currentTimeMillis() + EMERGENCY_WAIT_MILLIS
        while (procPath.exists() && System.currentTimeMillis() < deadline) {
            Thread.sleep(50L)
        }
    }

    private fun stateJson(
        generation: Long,
        status: String,
        outcomes: List<NodeOutcome>,
        message: String = "",
    ): String = JSONObject()
        .put("generation", generation)
        .put("status", status)
        .put("message", message)
        .put("optionalCheckActive", optionalCheckJob?.isActive == true)
        .put(
            "nodes",
            JSONArray().apply {
                outcomes.forEach { outcome ->
                    put(
                        JSONObject()
                            .put("nodeId", outcome.spec.nodeId)
                            .put("type", outcome.spec.type)
                            .put("ready", outcome.ready)
                            .put("reused", outcome.reused)
                            .put("message", outcome.message),
                    )
                }
            },
        )
        .toString()

    private const val LISTENER_CONNECT_TIMEOUT_MILLIS = 200L
    private const val LISTENER_MIN_RETRY_MILLIS = 20L
    private const val LISTENER_MAX_RETRY_MILLIS = 100L
    private const val SOFT_STOP_MILLIS = 500L
    private const val FORCE_STOP_MILLIS = 500L
    private const val EMERGENCY_WAIT_MILLIS = 500L
    private const val MAX_OUTPUT_LINES = 20
    private const val MAX_OUTPUT_LENGTH = 4096
    private const val MAX_PROBE_CONCURRENCY = 16
    private const val MAX_PROBE_NODES = 64

    // Ceiling for one system-DNS pass. Plan transitions preempt it outright,
    // but nothing else does, so no single pass may hold the plan lock for
    // `startup timeout x dependent nodes`; whatever is left over is finished by
    // the scheduled retry rather than by a longer lock hold.
    private const val DNS_UPDATE_BUDGET_MILLIS = 60_000L

    // Below this there is no point starting another node: it would fail on the
    // timeout and burn the restart for nothing.
    private const val DNS_RESTART_MIN_BUDGET_MILLIS = 5_000L

    private const val SYSTEM_DNS_RETRY_DELAY_MILLIS = 5_000L
    private const val MAX_SYSTEM_DNS_RETRIES = 3
}
