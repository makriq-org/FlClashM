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
import com.follow.clashx.service.modules.SuspendModule
import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

class FlVpnService : VpnService(), IBaseService {

    inner class LocalBinder : Binder() {
        val service: FlVpnService = this@FlVpnService
    }

    private val binder = LocalBinder()
    private val gson = Gson()
    @Volatile private var tunActive = false
    @Volatile private var revoked = false
    @Volatile override var destroyed = false

    private fun stopForegroundCompat() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    // The foreground notification keeps the process alive but does NOT stop Doze from
    // throttling the core's threads, so the tunnel needs a PARTIAL_WAKE_LOCK — but we
    // hold it only while the device is active. SuspendModule lowers it (setAwake(false))
    // once the system enters Doze so the CPU can deep-sleep, matching upstream's
    // no-permanent-wakelock battery profile, and raises it again on screen-on.
    private val wakeLockLock = Any()
    private var wakeLock: PowerManager.WakeLock? = null

    private fun acquireWakeLock() {
        synchronized(wakeLockLock) {
            if (wakeLock?.isHeld == true) return
            runCatching {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FlClashX:vpn-tunnel").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }.onFailure { GlobalState.log("acquireWakeLock failed: ${it.message}") }
        }
    }

    private fun releaseWakeLock() {
        synchronized(wakeLockLock) {
            runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
            wakeLock = null
        }
    }

    // Driven by SuspendModule from screen/Doze broadcasts. The tunActive re-check and
    // the acquire run under wakeLockLock — the same monitor releaseWakeLock() takes —
    // and handleStop() sets tunActive=false *before* releaseWakeLock(), so a late
    // in-flight broadcast cannot slip a stale re-acquire past teardown (the earlier
    // unsynchronized check left a TOCTOU window where acquire could land after the
    // teardown release). The nested acquire/release re-enter wakeLockLock, which is fine.
    fun setAwake(awake: Boolean) {
        synchronized(wakeLockLock) {
            if (!awake) {
                releaseWakeLock()
                return
            }
            if (!tunActive) return
            acquireWakeLock()
        }
    }

    private val healthCheckModule = HealthCheckModule(this)

    private val loader = moduleLoader {
        install { healthCheckModule }
        install { NetworkObserveModule(it, healthCheckModule) }
        install(::NotificationModule)
        install { SuspendModule(it, healthCheckModule) }
    }

    override fun onCreate() {
        super.onCreate()
        startForegroundCompat()
        handleCreate()
    }

    private fun startForegroundCompat() {
        val promoted = promoteToForeground(
            R.drawable.ic_notification,
            SavedParams.loadNotificationTitle(),
        )
        if (!promoted) {
            // FGS promotion denied (A12+ background restriction, e.g. a STICKY
            // restart). A started-but-not-foregrounded service crashes with
            // ForegroundServiceDidNotStartInTimeException ~10s later, and
            // START_STICKY would turn that into a crash-loop. Stop the started
            // state instead; an in-flight AIDL bind keeps the service alive.
            GlobalState.log("FlVpnService: foreground promotion denied, stopping")
            stopSelf()
        }
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
                    stopForegroundCompat()
                    stopSelf()
                }
            }
            return START_NOT_STICKY
        }
        // A null intent here is a START_STICKY auto-restart by the OS (every explicit
        // start — app-driven, tile, boot — passes a non-null Intent). onCreate has
        // already promoted the foreground notification; if there is no VPN to recover,
        // don't let that notification linger over a non-running core (the "висит до
        // последнего" orphan after an OEM force-stop). A genuinely-active tunnel
        // (isVpnActive) still falls through to coldStart and is restored.
        if (intent == null && !SavedParams.isVpnActive()) {
            GlobalState.log("FlVpnService: sticky restart with no active VPN, stopping")
            stopForegroundCompat()
            stopSelf()
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

    private suspend fun coldStart() {
        State.runLock.withLock {
            if (State.runTime != 0L) return@withLock
            StateHub.publish(StateHub.STARTING)
            try {
                coldStartLocked()
            } finally {
                // Every abort path in coldStartLocked stops the service; only a
                // completed start leaves runTime set. Publish the outcome exactly
                // once either way (the finally covers early returns and throws).
                if (State.runTime != 0L) {
                    StateHub.publishRunning()
                } else {
                    StateHub.publish(StateHub.STOPPED, message = "cold-start aborted")
                }
            }
        }
    }

    /** Caller must hold [State.runLock]. */
    private suspend fun coldStartLocked() {
        // The OS revoked the tunnel while this cold-start was queued; abort
        // so we don't bring up a tunnel the system is about to tear down.
        if (revoked) {
            GlobalState.log("Always-on: revoked before cold-start, aborting")
            stopForegroundCompat()
            stopSelf()
            return
        }

        if (!SavedParams.isVpnActive()) {
            GlobalState.log("Always-on: vpn not active, staying idle")
            stopForegroundCompat()
            stopSelf()
            return
        }

        val params = SavedParams.loadQuickStartParams() ?: run {
            GlobalState.log("Always-on: no saved params, cannot cold-start")
            stopForegroundCompat()
            stopSelf()
            return
        }

        val runtimeNodePlan = SavedParams.loadRuntimeNodesState() ?: "{\"nodes\":[]}"
        val runtimeNodeState = try {
            RuntimeNodeProcessManager.applyPlan(runtimeNodePlan)
        } catch (e: Exception) {
            GlobalState.log("Always-on: runtime-node state is invalid: ${e.message}")
            SavedParams.setVpnActive(false)
            stopForegroundCompat()
            stopSelf()
            return
        }
        if (!runtimeNodeState.contains("\"status\":\"ready\"") &&
            !runtimeNodeState.contains("\"status\":\"idle\"")
        ) {
            GlobalState.log("Always-on: failed to prepare runtime nodes: $runtimeNodeState")
            SavedParams.setVpnActive(false)
            runCatching { RuntimeNodeProcessManager.stopAll() }
            stopForegroundCompat()
            stopSelf()
            return
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
            return
        }

        if (coreResult.isNotEmpty()) {
            GlobalState.log("Always-on: quickStart returned error, aborting: $coreResult")
            SavedParams.setVpnActive(false)
            runCatching { RuntimeNodeProcessManager.stopAll() }
            runCatching { com.follow.clashx.core.Core.stopTun() }
            stopForegroundCompat()
            stopSelf()
            return
        }

        val optionsJson = Core.getAndroidVpnOptions()
        if (optionsJson.isBlank()) {
            // Empty options (core config not ready / marshal error) would fall
            // back to a default VpnOptions(): tunnel everything, no access
            // control — silently losing the user's split-tunneling. Abort
            // instead of bringing up the wrong tunnel headlessly.
            GlobalState.log("Always-on: empty vpn options, aborting cold-start")
            SavedParams.setVpnActive(false)
            runCatching { RuntimeNodeProcessManager.stopAll() }
            runCatching { com.follow.clashx.core.Core.stopTun() }
            stopForegroundCompat()
            stopSelf()
            return
        }
        val options = runCatching { gson.fromJson(optionsJson, VpnOptions::class.java) }
            .getOrDefault(VpnOptions())
            .gsonSanitized()

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
            return
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

    override fun onRevoke() {
        // onRevoke runs on the main thread; runBlocking here parks it on the
        // contended State.runLock (held by in-flight start/stop for up to ~15s),
        // which is well past the ANR threshold. Tear down asynchronously instead —
        // the OS removes the tunnel after onRevoke returns regardless.
        revoked = true
        GlobalState.launch {
            // No timeout: the lock may be held up to ~15s by an in-flight
            // start/cold-start. A bounded wait here would skip handleStop()
            // entirely and leave a zombie (core alive, wakeLock held,
            // isVpnActive=1, notification up) over a tunnel the OS already pulled.
            // The `revoked` flag makes a queued cold-start abort instead of racing.
            State.runLock.withLock { handleStop() }
            if (!destroyed) {
                stopForegroundCompat()
                stopSelf()
            }
        }
        super.onRevoke()
    }

    override fun onDestroy() {
        // tunActive=false BEFORE releaseWakeLock (mirrors handleStop): SuspendModule's
        // receiver is unregistered only inside loader.stop() below, so until then a
        // SCREEN_ON/DEVICE_IDLE broadcast → setAwake(true) would otherwise see
        // tunActive==true and re-acquire the wakelock past this release, leaking it
        // until the :remote process dies.
        tunActive = false
        releaseWakeLock()
        // Only stop the core TUN if this instance is STILL the owner. A fast
        // off→on may have handed ownership to a newer instance; closing the
        // global tun here (onDestroy is async, not under runLock) would kill the
        // new tunnel and leave a "connected" UI over a dead listener.
        if (State.tunOwner.compareAndSet(this, null)) {
            runCatching { com.follow.clashx.core.Core.stopTun() }
            // OS-driven destroy of a live tunnel (no handleStop ran): this
            // instance still owned the tun, so nothing newer is running — zero
            // runTime so handleDestroy() below reports an honest STOPPED.
            runCatching {
                runBlocking {
                    withTimeoutOrNull(3000L) {
                        RuntimeNodeProcessManager.stopIfIdle(vpnActive = false)
                    }
                }
            }
            State.runTime = 0L
            State.clearAppliedVpnOptions()
        }
        runCatching { runBlocking { withTimeoutOrNull(3000L) { loader.stop() } } }
        handleDestroy()
        super.onDestroy()
    }

    override suspend fun handleStart(options: VpnOptions) {
        val builder = Builder()
            .setSession("FlClashM")
        // Tunnel DNS comes from the core (it derives the in-tunnel resolver address from
        // the active config and hijacks :53 to it, resolving via the config's dns section)
        // — never a hardcoded public DNS. Fall back only to the standard in-tun resolver.
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

            // VpnService.Builder interprets zero addAllowedApplication calls as
            // "all applications". Remove our own package before deciding the mode,
            // so an empty resolved include list cannot override the hardened
            // rejectSelected self-bypass.
            allInclude.remove(packageName)
            if (allInclude.isNotEmpty()) {
                if (allExclude.isNotEmpty()) {
                    GlobalState.log("Access control: include-package active, exclude-package ignored (Android limitation)")
                }
                allInclude.forEach { runCatching { builder.addAllowedApplication(it) } }
            } else if (
                allExclude.isNotEmpty() || includeModeRequested || excludeModeRequested
            ) {
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
            // Acquire the tunnel wakelock only now, after establish() has succeeded.
            // Acquiring it before this try leaked the lock if Builder setup / establish()
            // threw: the unwind's ACTION_STOP → handleStop early-returns
            // (runTime==0 && !tunActive) without ever reaching releaseWakeLock().
            acquireWakeLock()
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
            // Claim TUN ownership: from here this instance owns the native core's
            // tun. onDestroy releases it via CAS so a delayed teardown of THIS
            // instance can't close a tunnel a newer instance has since brought up.
            State.tunOwner.set(this)
            State.publishAppliedVpnOptions(options)
        } catch (e: Exception) {
            State.clearAppliedVpnOptions()
            tunActive = false
            // tunActive=false before releaseWakeLock (mirrors handleStop) so an
            // in-flight setAwake(true) can't re-acquire the lock past this release.
            releaseWakeLock()
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
        State.clearAppliedVpnOptions()
        tunActive = false
        releaseWakeLock()
        SavedParams.setVpnActive(false)
        // NOTE: do NOT clear cold-start params here — they must persist so a later
        // tile/widget start can bring the tunnel up headlessly without opening the app.
        // Stale-profile safety comes from the isVpnActive() gate (cleared above) plus
        // re-persisting params on profile change (controller._persistColdStartParams).
        runCatching { com.follow.clashx.core.Core.stopTun() }
        runCatching { RuntimeNodeProcessManager.stopIfIdle(vpnActive = false) }
        // Release ownership so the trailing onDestroy doesn't redundantly stop the
        // core (CAS will no-op once cleared).
        State.tunOwner.compareAndSet(this, null)
        loader.stop()
        handleDestroy()
        stopSelf()
    }

}
