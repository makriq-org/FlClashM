package com.follow.clashx.service

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import com.follow.clashx.common.GlobalState
import com.follow.clashx.core.Core
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.models.toCIDR
import com.follow.clashx.service.modules.NotificationModule
import com.follow.clashx.service.modules.promoteServiceForeground
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/** VPN descriptors and Android resources only; Go owns every runtime intent. */
class FlVpnService : VpnService(), BackendForegroundResource {
    private val resources = Any()
    @Volatile private var tunActive = false
    @Volatile private var revoked = false
    @Volatile override var destroyed = false
    @Volatile private var lastStartId = 0
    private val notifications = NotificationModule(this)

    override fun onCreate() {
        super.onCreate()
        handleCreate()
        if (promoteServiceForeground()) {
            BackendForegroundHold.created(this)
            GlobalState.launch { notifications.install() }
        } else { stopSelf() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val promoted = promoteServiceForeground()
        if (promoted) BackendForegroundHold.created(this)
        if (intent?.action == BackendForegroundHold.ACTION_HOLD) {
            BackendForegroundHold.acknowledge(intent.getStringExtra("operationId"), promoted)
            return START_NOT_STICKY
        }
        if (!promoted) { stopSelf(); return START_NOT_STICKY }
        val method = ServiceStartCommand.backendMethod(intent?.action) ?: return START_STICKY
        GlobalState.launch {
            runCatching {
                BackendHost.initialize()
                BackendHost.command(method)
            }.onSuccess {
                // A Stop that found nothing running must not leave this host behind.
                if (method == "runtime.stop") finishIfIdle()
            }.onFailure { GlobalState.log("VPN OS command failed: ${it.message}"); finishIfIdle() }
        }
        return if (ServiceStartCommand.sticky(method)) START_STICKY else START_NOT_STICKY
    }

    override fun onRevoke() {
        val owned = synchronized(resources) {
            revoked = true
            val owned = State.tunOwner.compareAndSet(this, null)
            if (owned) {
                tunActive = false
                Core.stopTun()
                State.runTime = 0L
                State.clearAppliedVpnOptions()
            }
            owned
        }
        releaseWakeLock()
        if (owned) BackendOSObserver.service("revoked")
        super.onRevoke()
    }

    override fun onDestroy() {
        val owned = synchronized(resources) {
            destroyed = true
            tunActive = false
            val owned = State.tunOwner.compareAndSet(this, null)
            if (owned) {
                Core.stopTun()
                State.runTime = 0L
                State.clearAppliedVpnOptions()
            }
            owned
        }
        releaseWakeLock()
        if (owned) BackendOSObserver.service("service")
        BackendForegroundHold.destroyed(this)
        runCatching { runBlocking { withTimeoutOrNull(3_000L) { notifications.uninstall() } } }
        super.onDestroy()
    }

    override fun finishIfIdle() {
        BackendForegroundHold.retireIfIdle(this, { !tunActive }) { stopSelfResult(lastStartId) }
    }

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

    // Mechanical resource effect requested by the Go screen/Doze policy.
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

    override suspend fun handleStart(options: VpnOptions) {
        check(!destroyed && !revoked && BackendForegroundHold.isLive(this)) { "VPN service is unavailable" }
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

        // Go supplies the final package policy. Builder applies it literally.
        options.accessControl?.let { access ->
            when (access.mode) {
                com.follow.clashx.common.AccessControlMode.acceptSelected -> {
                    var installed = 0
                    access.acceptList.forEach { name ->
                        try { builder.addAllowedApplication(name); installed++ }
                        catch (_: android.content.pm.PackageManager.NameNotFoundException) {}
                    }
                    check(installed > 0) { "No compiled allowed application is installed" }
                }
                com.follow.clashx.common.AccessControlMode.rejectSelected ->
                    access.rejectList.forEach { name ->
                        try { builder.addDisallowedApplication(name) }
                        catch (_: android.content.pm.PackageManager.NameNotFoundException) {}
                    }
            }
        }

        if (options.allowBypass) builder.allowBypass()

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            options.systemProxy &&
            options.port in 1..65535
        ) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    "127.0.0.1",
                    options.port,
                    options.bypassDomain,
                ),
            )
        }

        builder.setBlocking(false)

        synchronized(resources) {
            check(!destroyed && !revoked) { "VPN service is unavailable" }
            val pfd = builder.establish() ?: error("VpnService.Builder.establish() returned null")
            val fd = pfd.detachFd()
            tunActive = true
            // Ownership boundary: we own the fd until the native core is invoked; from
            // Core.startTun onward the core/sing-tun owns it (and closes it on teardown
            // or on its own failure paths). Reclaiming it again after handoff could
            // double-close a number the core may have already reused, so only close it
            // here if the core was never reached.
            var fdHandedToCore = false
            try {
                // Acquire the tunnel wakelock only now, after establish() has succeeded.
                // Acquiring it before this try leaked the lock if Builder setup / establish()
                // threw: the unwind's ACTION_STOP → handleStop early-returns
                // (runTime==0 && !tunActive) without ever reaching releaseWakeLock().
                acquireWakeLock()
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
                check(!destroyed && !revoked) { "VPN service disappeared during start" }
                // Claim TUN ownership: from here this instance owns the native core's
                // tun. onDestroy releases it via CAS so a delayed teardown of THIS
                // instance can't close a tunnel a newer instance has since brought up.
                State.tunOwner.set(this)
                State.publishAppliedVpnOptions(options)
                State.runTime = android.os.SystemClock.uptimeMillis()
            } catch (e: Exception) {
                State.clearAppliedVpnOptions()
                tunActive = false
                // tunActive=false before releaseWakeLock (mirrors handleStop) so an
                // in-flight setAwake(true) can't re-acquire the lock past this release.
                releaseWakeLock()
                // Roll back a partially-completed start: stop modules and native core
                // before reclaiming the fd, so no orphaned Go core / module survives.
                runCatching { com.follow.clashx.core.Core.stopTun() }
                if (!fdHandedToCore) {
                    // Core never received the fd; reclaim it. Once handed off the core
                    // (and sing-tun) own and close it — see core/lib_android.go.
                    runCatching { android.os.ParcelFileDescriptor.adoptFd(fd).close() }
                }
                throw e
            }
        }
    }

    override suspend fun handleStop() {
        synchronized(resources) {
            tunActive = false
            if (State.tunOwner.compareAndSet(this, null)) {
                Core.stopTun()
                State.runTime = 0L
                State.clearAppliedVpnOptions()
            }
        }
        releaseWakeLock()
        finishIfIdle()
    }
}
