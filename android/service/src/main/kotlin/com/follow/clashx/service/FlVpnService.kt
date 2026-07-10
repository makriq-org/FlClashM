package com.follow.clashx.service

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Binder
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.SavedParams
import com.follow.clashx.common.promoteToForeground
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.models.gsonSanitized
import com.follow.clashx.service.models.toCIDR
import com.follow.clashx.service.modules.HealthCheckModule
import com.follow.clashx.service.modules.NetworkObserveModule
import com.follow.clashx.service.modules.NotificationModule
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.Socket
import kotlin.coroutines.resume

class FlVpnService : VpnService(), IBaseService {

    inner class LocalBinder : Binder() {
        val service: FlVpnService = this@FlVpnService
    }

    private val binder = LocalBinder()
    private val gson = Gson()
    @Volatile private var tunActive = false
    @Volatile override var destroyed = false

    // Held for the tunnel's lifetime so Doze/App-Standby can't throttle the core's
    // threads to sleep while the VPN is up (the foreground notification keeps the
    // process alive but does NOT prevent CPU/network throttling under Doze).
    private var wakeLock: PowerManager.WakeLock? = null

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        runCatching {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FlClashX:vpn-tunnel").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.onFailure { GlobalState.log("acquireWakeLock failed: ${it.message}") }
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    private val healthCheckModule = HealthCheckModule(this)

    private val loader = moduleLoader {
        install { healthCheckModule }
        install { NetworkObserveModule(it, healthCheckModule) }
        install(::NotificationModule)
    }

    override fun onCreate() {
        super.onCreate()
        startForegroundCompat()
        handleCreate()
    }

    private fun startForegroundCompat() {
        promoteToForeground(
            R.drawable.ic_notification,
            SavedParams.loadNotificationTitle(),
        )
    }

    override fun onBind(intent: Intent?): IBinder {
        return if (intent?.action == SERVICE_INTERFACE) super.onBind(intent) ?: binder else binder
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            GlobalState.launch {
                State.runLock.withLock { handleStop() }
                // handleStop early-returns when nothing is running; for a recreated-
                // then-stopped process that still left the foreground notification up,
                // guarantee teardown so no empty foreground service lingers.
                if (!destroyed) {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    } else {
                        @Suppress("DEPRECATION")
                        stopForeground(true)
                    }
                    stopSelf()
                }
            }
            return START_NOT_STICKY
        }
        if (State.runTime == 0L) {
            GlobalState.launch { coldStart() }
        }
        return START_STICKY
    }

    companion object {
        const val ACTION_STOP = "com.makriq.flclash.service.STOP"
    }

    data class ColdStartRuntimeNode(
        val nodeId: String,
        val executablePath: String,
        val workingDirectory: String,
        val host: String,
        val port: Int,
        val arguments: List<String> = emptyList(),
    )

    private suspend fun coldStart() {
        State.runLock.withLock {
            if (State.runTime != 0L) return@withLock

            if (!SavedParams.isVpnActive()) {
                GlobalState.log("Always-on: vpn not active, staying idle")
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return@withLock
            }

            val params = SavedParams.loadQuickStartParams() ?: run {
                GlobalState.log("Always-on: no saved params, cannot cold-start")
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return@withLock
            }

            val runtimeNodes = try {
                loadColdStartRuntimeNodes()
            } catch (e: Exception) {
                GlobalState.log("Always-on: runtime-node state is invalid: ${e.message}")
                SavedParams.setVpnActive(false)
                stopForegroundCompat()
                stopSelf()
                return@withLock
            }

            try {
                startColdStartRuntimeNodes(runtimeNodes)
            } catch (e: Exception) {
                GlobalState.log("Always-on: failed to start runtime nodes: ${e.message}")
                SavedParams.setVpnActive(false)
                runCatching { RuntimeNodeProcessManager.stopAll() }
                stopForegroundCompat()
                stopSelf()
                return@withLock
            }

            val coreResult = withTimeoutOrNull(15_000L) {
                suspendCancellableCoroutine { cont ->
                    Core.quickStart(params.init, params.setup, params.state, object : InvokeInterface {
                        override fun onResult(result: String) {
                            if (cont.isActive) cont.resume(result)
                        }
                    })
                }
            }

            if (coreResult == null) {
                GlobalState.log("Always-on: quickStart timed out")
                SavedParams.setVpnActive(false)
                runCatching { RuntimeNodeProcessManager.stopAll() }
                runCatching { com.follow.clashx.core.Core.stopTun() }
                stopForegroundCompat()
                stopSelf()
                return@withLock
            }

            if (coreResult.isNotEmpty()) {
                GlobalState.log("Always-on: quickStart returned error, aborting: $coreResult")
                SavedParams.setVpnActive(false)
                runCatching { RuntimeNodeProcessManager.stopAll() }
                runCatching { com.follow.clashx.core.Core.stopTun() }
                stopForegroundCompat()
                stopSelf()
                return@withLock
            }

            val optionsJson = Core.getAndroidVpnOptions()
            val options = (if (optionsJson.isNotBlank()) {
                runCatching { gson.fromJson(optionsJson, VpnOptions::class.java) }
                    .getOrDefault(VpnOptions())
            } else VpnOptions()).gsonSanitized()

            State.options = options
            State.notificationParamsFlow.value = State.notificationParamsFlow.value.copy(
                title = SavedParams.loadNotificationTitle(),
            )

            runCatching {
                handleStart(options)
            }.onFailure {
                GlobalState.log("Always-on: handleStart failed: ${it.message}")
                SavedParams.setVpnActive(false)
                runCatching { RuntimeNodeProcessManager.stopAll() }
                runCatching { com.follow.clashx.core.Core.stopTun() }
                stopForegroundCompat()
                stopSelf()
                return@withLock
            }

            State.runTime = SystemClock.uptimeMillis()
            SavedParams.setVpnActive(true)
            GlobalState.log("Always-on cold-start completed, runTime=${State.runTime}")
            // Headless: no Flutter UI exists to drive setUiActive, and the core
            // defaults uiActive=true. Left true, the health-check forwarder keeps
            // every proxy provider's url-test warm — pinging the whole node list over
            // the radio every interval, forever, screen-off. Drop to background
            // cadence now; when a UI later attaches it raises uiActive (true) again.
            runCatching {
                val action =
                    """{"id":"uia_${System.currentTimeMillis()}","method":"setUiActive","data":false}"""
                Core.invokeAction(action, object : InvokeInterface {
                    override fun onResult(result: String) {}
                })
            }
        }
    }

    override fun onRevoke() {
        // onRevoke runs on the main thread; runBlocking here parks it on the
        // contended State.runLock (held by in-flight start/stop for up to ~10s),
        // which is well past the ANR threshold. Tear down asynchronously instead —
        // the OS removes the tunnel after onRevoke returns regardless.
        GlobalState.launch {
            withTimeoutOrNull(5000L) {
                State.runLock.withLock { handleStop() }
            }
        }
        super.onRevoke()
    }

    override fun onDestroy() {
        releaseWakeLock()
        runCatching { runBlocking { withTimeoutOrNull(3000L) { RuntimeNodeProcessManager.stopAll() } } }
        runCatching { com.follow.clashx.core.Core.stopTun() }
        runCatching { runBlocking { withTimeoutOrNull(3000L) { loader.stop() } } }
        tunActive = false
        handleDestroy()
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun loadColdStartRuntimeNodes(): List<ColdStartRuntimeNode> {
        val state = SavedParams.loadRuntimeNodesState() ?: return emptyList()
        val root = JSONObject(state)
        val rawNodes = root.optJSONArray("nodes") ?: JSONArray()
        return buildList {
            for (index in 0 until rawNodes.length()) {
                val rawNode = rawNodes.optJSONObject(index) ?: continue
                val nodeId = rawNode.optString("nodeId", "").trim()
                val executablePath = rawNode.optString("executablePath", "").trim()
                val workingDirectory = rawNode.optString("workingDirectory", "").trim()
                val host = rawNode.optString("host", "").trim()
                val port = rawNode.optInt("port", 0)
                val rawArguments = rawNode.optJSONArray("arguments") ?: JSONArray()
                val arguments = buildList {
                    for (argumentIndex in 0 until rawArguments.length()) {
                        val argument = rawArguments.optString(argumentIndex, "")
                        if (argument.isNotEmpty()) add(argument)
                    }
                }
                if (nodeId.isEmpty() || executablePath.isEmpty() || workingDirectory.isEmpty() ||
                    host.isEmpty() || port <= 0
                ) {
                    throw IllegalStateException("Runtime node state is incomplete at index $index")
                }
                add(
                    ColdStartRuntimeNode(
                        nodeId = nodeId,
                        executablePath = executablePath,
                        workingDirectory = workingDirectory,
                        host = host,
                        port = port,
                        arguments = arguments,
                    ),
                )
            }
        }
    }

    private suspend fun startColdStartRuntimeNodes(nodes: List<ColdStartRuntimeNode>) {
        for (node in nodes) {
            val startedAt = RuntimeNodeProcessManager.start(
                nodeId = node.nodeId,
                executablePath = node.executablePath,
                workingDirectory = node.workingDirectory,
                arguments = node.arguments,
            )
            if (startedAt <= 0L) {
                throw IllegalStateException("Runtime node `${node.nodeId}` did not start")
            }
            waitForRuntimeNodeListener(node.host, node.port)
        }
    }

    private suspend fun waitForRuntimeNodeListener(host: String, port: Int) {
        withContext(Dispatchers.IO) {
            repeat(50) { attempt ->
                runCatching {
                    Socket(host, port).use { socket ->
                        socket.soTimeout = 200
                    }
                    return@withContext
                }
                if (attempt == 49) {
                    throw IllegalStateException("Timed out waiting for runtime node listener on $host:$port")
                }
                kotlinx.coroutines.delay(100L)
            }
        }
    }

    override suspend fun handleStart(options: VpnOptions) {
        State.options = options
        acquireWakeLock()
        val builder = Builder().setSession("FlClashM")
        // Tunnel DNS comes from the core's current config. Fall back only to the
        // in-tun resolver address when the option is absent.
        builder.addDnsServer(options.dnsServerAddress.ifBlank { "172.19.0.2" })

        if (options.ipv4) options.ipv4Address.toCIDR()?.let { (addr, p) -> builder.addAddress(addr, p) }
        if (options.ipv6) options.ipv6Address.toCIDR()?.let { (addr, p) -> builder.addAddress(addr, p) }

        val filteredRoutes = options.routeAddress.mapNotNull { it.toCIDR() }
            .filter { (addr, _) ->
                val isV6 = addr.contains(':')
                if (isV6) options.ipv6 else options.ipv4
            }
        if (filteredRoutes.isNotEmpty()) {
            filteredRoutes.forEach { (addr, p) -> builder.addRoute(addr, p) }
        } else {
            if (options.ipv4) builder.addRoute("0.0.0.0", 0)
            if (options.ipv6) builder.addRoute("::", 0)
        }

        runCatching {
            val ac = options.accessControl
            val include = options.includePackage.orEmpty()
            val exclude = options.excludePackage.orEmpty()
            val includeModeRequested =
                ac?.mode == com.follow.clashx.common.AccessControlMode.acceptSelected ||
                    options.includePackage != null
            val excludeModeRequested =
                ac?.mode == com.follow.clashx.common.AccessControlMode.rejectSelected ||
                    options.excludePackage != null

            val allInclude = mutableSetOf<String>()
            val allExclude = mutableSetOf<String>()

            if (ac != null) {
                when (ac.mode) {
                    com.follow.clashx.common.AccessControlMode.acceptSelected ->
                        allInclude.addAll(ac.acceptList)
                    com.follow.clashx.common.AccessControlMode.rejectSelected ->
                        allExclude.addAll(ac.rejectList)
                }
            }
            allInclude.addAll(include)
            allExclude.addAll(exclude)

            if (includeModeRequested) {
                if (allExclude.isNotEmpty()) {
                    GlobalState.log("Access control: include-package active, exclude-package ignored (Android limitation)")
                }
                allInclude.remove(packageName)
                allInclude.forEach { runCatching { builder.addAllowedApplication(it) } }
            } else if (excludeModeRequested) {
                allExclude.add(packageName)
                allExclude.forEach { runCatching { builder.addDisallowedApplication(it) } }
            }
        }

        if (options.allowBypass) builder.allowBypass()

        builder.setBlocking(false)

        val pfd = builder.establish() ?: error("VpnService.Builder.establish() returned null")
        val fd = pfd.detachFd()
        tunActive = true
        // Ownership boundary: we own the fd until the native core is invoked; from
        // Core.startTun onward the core/sing-tun owns it (and closes it on teardown
        // or on its own failure paths). Reclaiming it again after handoff could
        // double-close a number the core may have already reused, so only close it
        // here if the core was never reached (loader.start threw before handoff).
        var fdHandedToCore = false
        try {
            loader.start()
            fdHandedToCore = true

            val started = com.follow.clashx.core.Core.startTun(
                fd = fd,
                protect = { fdToProtect -> protect(fdToProtect) },
                resolverProcess = { protocol, source, target, uid ->
                    val resolvedUid = if (uid > 0) uid else {
                        // getConnectionOwnerUid is API 29+; on older devices the call
                        // throws NoSuchMethodError (an Error, not an Exception), so guard
                        // by version and catch Throwable to avoid crashing the resolver.
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                            try {
                                val cm = getSystemService(ConnectivityManager::class.java)
                                val proto = if (protocol == 6) android.system.OsConstants.IPPROTO_TCP
                                            else android.system.OsConstants.IPPROTO_UDP
                                cm.getConnectionOwnerUid(proto, source, target)
                            } catch (_: Throwable) { -1 }
                        } else -1
                    }
                    if (resolvedUid <= 0) return@startTun ""
                    packageManager.getPackagesForUid(resolvedUid)?.firstOrNull() ?: ""
                },
            )
            if (!started) error("Core.startTun failed")
        } catch (e: Exception) {
            tunActive = false
            // Roll back a partially-completed start: stop modules and native core
            // before reclaiming the fd, so no orphaned Go core / module survives.
            runCatching { loader.stop() }
            runCatching { com.follow.clashx.core.Core.stopTun() }
            if (!fdHandedToCore) {
                // Core never received the fd; reclaim it. Once handed off the core
                // (and sing-tun) own and close it — see core/lib_android.go.
                runCatching { android.os.ParcelFileDescriptor.adoptFd(fd).close() }
            }
            throw e
        }
    }

    override suspend fun handleStop() {
        if (State.runTime == 0L && !tunActive) return
        State.runTime = 0L
        tunActive = false
        releaseWakeLock()
        SavedParams.setVpnActive(false)
        // NOTE: do NOT clear cold-start params here — they must persist so a later
        // tile/widget start can bring the tunnel up headlessly without opening the app.
        // Stale-profile safety comes from the isVpnActive() gate (cleared above) plus
        // re-persisting params on profile change (controller._persistColdStartParams).
        runCatching { com.follow.clashx.core.Core.stopTun() }
        loader.stop()
        handleDestroy()
        stopSelf()
    }

}
