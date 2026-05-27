package com.follow.clashx.service

import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Binder
import android.os.IBinder
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
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

class FlVpnService : VpnService(), IBaseService {

    inner class LocalBinder : Binder() {
        val service: FlVpnService = this@FlVpnService
    }

    private val binder = LocalBinder()
    private val gson = Gson()
    @Volatile private var tunActive = false
    @Volatile override var destroyed = false

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
            GlobalState.launch { State.runLock.withLock { handleStop() } }
            return START_NOT_STICKY
        }
        if (State.runTime == 0L) {
            GlobalState.launch { coldStart() }
        }
        return START_STICKY
    }

    companion object {
        const val ACTION_STOP = "com.follow.clashx.service.STOP"
    }

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
                runCatching { com.follow.clashx.core.Core.stopTun() }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return@withLock
            }

            if (coreResult.isNotEmpty()) {
                GlobalState.log("Always-on: quickStart returned error, aborting: $coreResult")
                SavedParams.setVpnActive(false)
                runCatching { com.follow.clashx.core.Core.stopTun() }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
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
                runCatching { com.follow.clashx.core.Core.stopTun() }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return@withLock
            }

            State.runTime = SystemClock.uptimeMillis()
            SavedParams.setVpnActive(true)
            GlobalState.log("Always-on cold-start completed, runTime=${State.runTime}")
        }
    }

    override fun onRevoke() {
        runBlocking {
            withTimeoutOrNull(5000L) {
                State.runLock.withLock { handleStop() }
            }
        }
        super.onRevoke()
    }

    override fun onDestroy() {
        runCatching { com.follow.clashx.core.Core.stopTun() }
        runCatching { runBlocking { withTimeoutOrNull(3000L) { loader.stop() } } }
        tunActive = false
        handleDestroy()
        super.onDestroy()
    }

    override suspend fun handleStart(options: VpnOptions) {
        State.options = options
        val builder = Builder()
            .setSession("FlClashX")
        for (dns in options.dnsServers.ifEmpty { listOf("8.8.8.8", "1.1.1.1") }) {
            builder.addDnsServer(dns)
        }

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

            if (allInclude.isNotEmpty()) {
                if (allExclude.isNotEmpty()) {
                    GlobalState.log("Access control: include-package active, exclude-package ignored (Android limitation)")
                }
                allInclude.add(packageName)
                allInclude.forEach { runCatching { builder.addAllowedApplication(it) } }
            } else if (allExclude.isNotEmpty()) {
                allExclude.forEach { runCatching { builder.addDisallowedApplication(it) } }
            }
        }

        builder.setBlocking(false)

        val pfd = builder.establish() ?: error("VpnService.Builder.establish() returned null")
        val fd = pfd.detachFd()
        tunActive = true
        try {
            loader.start()

            val started = com.follow.clashx.core.Core.startTun(
                fd = fd,
                protect = { fdToProtect -> protect(fdToProtect) },
                resolverProcess = { protocol, source, target, uid ->
                    val resolvedUid = if (uid > 0) uid else {
                        try {
                            val cm = getSystemService(ConnectivityManager::class.java)
                            val proto = if (protocol == 6) android.system.OsConstants.IPPROTO_TCP
                                        else android.system.OsConstants.IPPROTO_UDP
                            cm.getConnectionOwnerUid(proto, source, target)
                        } catch (_: Exception) { -1 }
                    }
                    if (resolvedUid <= 0) return@startTun ""
                    packageManager.getPackagesForUid(resolvedUid)?.firstOrNull() ?: ""
                },
            )
            if (!started) error("Core.startTun failed")
        } catch (e: Exception) {
            tunActive = false
            runCatching { android.os.ParcelFileDescriptor.adoptFd(fd).close() }
            throw e
        }
    }

    override suspend fun handleStop() {
        if (State.runTime == 0L && !tunActive) return
        State.runTime = 0L
        tunActive = false
        SavedParams.setVpnActive(false)
        runCatching { com.follow.clashx.core.Core.stopTun() }
        loader.stop()
        handleDestroy()
        stopSelf()
    }

}
