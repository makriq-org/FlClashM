package com.follow.clashx.service

import android.os.SystemClock
import com.follow.clashx.common.GlobalState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
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

    // Last DNS servers seen on the physical network. Held here, not in Dart,
    // so cold start and DNS changes work with no Flutter process running.
    @Volatile private var latestSystemDns: List<String> = emptyList()
    @Volatile private var lastAppliedSystemDns: List<String>? = null

    /**
     * DNS servers to render resolver files with. Falls back to reading the
     * platform directly, so a cold start that runs before any network observer
     * is installed still produces a usable resolver list.
     */
    private fun currentSystemDns(): List<String> {
        val cached = latestSystemDns
        if (cached.isNotEmpty()) return cached
        val resolved = SystemDnsReader.read()
        if (resolved.isNotEmpty()) latestSystemDns = resolved
        return resolved
    }

    private val planLock = Mutex()
    private val planTransitionLock = Mutex()
    private val nodeLocks = ConcurrentHashMap<String, Mutex>()
    private val runningNodes = ConcurrentHashMap<String, RunningNode>()
    private val activeBatchProbeJobs = mutableSetOf<Job>()
    private val readyNodeIds = ConcurrentHashMap.newKeySet<String>()
    private var activePlan = linkedMapOf<String, RuntimeNodeSpec>()
    private var acceptingBatchProbes = true
    @Volatile private var generation = 0L
    private var optionalCheckJob: Job? = null
    @Volatile private var lastStateJson = stateJson(0L, "idle", emptyList())

    suspend fun applyPlan(planJson: String): String =
        withBatchProbesStopped {
        val target = parsePlan(planJson)
        val previousPlan = activePlan
        val previousReady = readyNodeIds.toSet()
        val reusable = target.filter { (nodeId, spec) ->
            previousPlan[nodeId] == spec &&
                nodeId in previousReady &&
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
     */
    suspend fun updateSystemDns(dnsServers: List<String>) = withBatchProbesStopped {
        val normalized = dnsServers.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        latestSystemDns = normalized
        if (normalized == lastAppliedSystemDns) return@withBatchProbesStopped

        val dependents = activePlan.values.filter {
            it.resolverFile?.dependsOnSystemDns == true
        }
        if (dependents.isEmpty()) {
            lastAppliedSystemDns = normalized
            return@withBatchProbesStopped
        }
        generation += 1L
        val currentGeneration = generation
        optionalCheckJob?.cancelAndJoin()
        optionalCheckJob = null
        val restartedNodeIds = mutableSetOf<String>()
        val failures = mutableMapOf<String, String>()

        for (spec in dependents) {
            val resolverFile = spec.resolverFile ?: continue
            val runtimeDir = File(spec.workingDirectory)
            val renderResult = withContext(Dispatchers.IO) {
                RuntimeNodeResolverFileWriter.render(
                    workingDirectory = runtimeDir,
                    spec = resolverFile,
                    systemDns = normalized,
                )
            }
            if (renderResult == RuntimeNodeResolverFileRenderResult.UNCHANGED) continue
            if (renderResult == RuntimeNodeResolverFileRenderResult.FAILED) {
                GlobalState.log(
                    "Could not render resolver file for runtime node `${spec.nodeId}`",
                )
                stop(spec.nodeId)
                readyNodeIds.remove(spec.nodeId)
                failures[spec.nodeId] = "Could not render the resolver file"
                continue
            }
            restartedNodeIds.add(spec.nodeId)
            val wasRunning = readStartTime(spec.nodeId) > 0L
            if (wasRunning) {
                stop(spec.nodeId)
                readyNodeIds.remove(spec.nodeId)
            }

            val reset = withContext(Dispatchers.IO) {
                RuntimeNodeResolverFileWriter.resetDeclaredPaths(runtimeDir, resolverFile)
            }
            if (!reset) {
                GlobalState.log(
                    "Could not reset resolver-dependent state for runtime node `${spec.nodeId}`",
                )
                failures[spec.nodeId] = "Could not reset resolver-dependent state"
                continue
            }

            // Only nodes that are actually running are restarted; a sleeping
            // reserve node picks the new list up when it is next started.
            if (!wasRunning) continue
            GlobalState.log("Restarting runtime node `${spec.nodeId}` after a system DNS change")
            val outcome = prepareNode(spec)
            if (outcome.ready) {
                readyNodeIds.add(spec.nodeId)
            } else {
                readyNodeIds.remove(spec.nodeId)
                failures[spec.nodeId] = outcome.message
                GlobalState.log(
                    "Runtime node `${spec.nodeId}` failed to restart after a DNS change: " +
                        outcome.message,
                )
            }
        }

        val outcomes = activePlan.values.map { spec ->
            val ready = spec.nodeId in readyNodeIds && readStartTime(spec.nodeId) > 0L
            val message = failures[spec.nodeId]
                ?: if (ready) {
                    ""
                } else {
                    readLastError(spec.nodeId).ifBlank {
                        "Runtime node `${spec.nodeId}` is not running"
                    }
                }
            NodeOutcome(
                spec = spec,
                ready = ready,
                reused = ready && spec.nodeId !in restartedNodeIds,
                message = message,
            )
        }
        val failure = outcomes.firstOrNull { !it.ready }
        lastStateJson = stateJson(
            currentGeneration,
            if (failure == null) "ready" else "failed",
            outcomes,
            failure?.message.orEmpty(),
        )
        if (failures.isEmpty()) {
            lastAppliedSystemDns = normalized
        }
        if (failure == null) {
            launchOptionalChecks(currentGeneration, activePlan.values.toList())
        }
    }

    suspend fun stopAll() = withBatchProbesStopped {
        optionalCheckJob?.cancelAndJoin()
        optionalCheckJob = null
        stopAllProcesses()
        activePlan = linkedMapOf()
        readyNodeIds.clear()
        generation += 1L
        lastStateJson = stateJson(generation, "idle", emptyList())
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

    private suspend fun prepareNode(spec: RuntimeNodeSpec): NodeOutcome {
        return runCatching {
            val startedAt = start(spec)
            check(startedAt > 0L) { "Runtime node `${spec.nodeId}` did not start" }
            val deadline =
                SystemClock.elapsedRealtime() + spec.connectivityCheck.startupTimeoutMillis
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
                delay(minOf(LISTENER_RETRY_MILLIS, remaining))
            }
        }
    }

    private suspend fun start(spec: RuntimeNodeSpec): Long {
        val lock = nodeLocks.getOrPut(spec.nodeId) { Mutex() }
        return lock.withLock {
            withContext(Dispatchers.IO) {
                val running = runningNodes[spec.nodeId]
                if (running?.process?.isAlive == true && running.spec == spec) {
                    return@withContext running.startTimeMillis
                }
                if (running != null) stopInternal(spec.nodeId)

                val executable = File(spec.executablePath)
                if (!executable.exists()) {
                    GlobalState.log("runtime node binary is missing: ${spec.executablePath}")
                    return@withContext 0L
                }
                if (executable.canWrite()) {
                    executable.setExecutable(true, true)
                } else if (!executable.canExecute()) {
                    GlobalState.log("runtime node binary is not executable: ${spec.executablePath}")
                    return@withContext 0L
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
                    if (renderResult == RuntimeNodeResolverFileRenderResult.FAILED) {
                        GlobalState.log(
                            "Could not render resolver file for runtime node `${spec.nodeId}`",
                        )
                        return@withContext 0L
                    }
                    if (
                        renderResult == RuntimeNodeResolverFileRenderResult.CHANGED &&
                        !RuntimeNodeResolverFileWriter.resetDeclaredPaths(
                            runtimeDir,
                            resolverFile,
                        )
                    ) {
                        GlobalState.log(
                            "Could not reset resolver-dependent state for runtime node `${spec.nodeId}`",
                        )
                        return@withContext 0L
                    }
                }
                val process = try {
                    ProcessBuilder(listOf(spec.executablePath) + spec.arguments)
                        .directory(runtimeDir)
                        .redirectErrorStream(true)
                        .start()
                } catch (error: Exception) {
                    GlobalState.log(
                        "Failed to start runtime node `${spec.nodeId}`: ${error.message}",
                    )
                    return@withContext 0L
                }

                val startedAt = System.currentTimeMillis()
                val output = OutputBuffer()
                val logJob = GlobalState.scope.launch(Dispatchers.IO) {
                    runCatching {
                        process.inputStream.bufferedReader().useLines { lines ->
                            lines.forEach { line ->
                                if (line.isNotBlank()) {
                                    output.add(line)
                                    GlobalState.log("[runtime-node:${spec.nodeId}] $line")
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
    private const val LISTENER_RETRY_MILLIS = 100L
    private const val SOFT_STOP_MILLIS = 500L
    private const val FORCE_STOP_MILLIS = 500L
    private const val EMERGENCY_WAIT_MILLIS = 500L
    private const val MAX_OUTPUT_LINES = 20
    private const val MAX_OUTPUT_LENGTH = 4096
    private const val MAX_PROBE_CONCURRENCY = 16
    private const val MAX_PROBE_NODES = 64
}
