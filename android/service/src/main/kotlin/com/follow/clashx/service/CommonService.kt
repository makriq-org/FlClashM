package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.IBinder
import com.follow.clashx.common.GlobalState
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.modules.NotificationModule
import com.follow.clashx.service.modules.promoteServiceForeground
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/** Foreground lifetime for backend operations and execution, independently of
 * the VPN system binding. Also provides the proxy-only platform resource. */
class CommonService : Service(), BackendForegroundResource {
    private val resources = Any()
    @Volatile override var destroyed = false
    @Volatile private var active = false
    @Volatile private var lastStartId = 0
    private val notifications = NotificationModule(this)

    override fun onCreate() {
        super.onCreate()
        handleCreate()
        if (promoteServiceForeground()) {
            BackendForegroundHold.created(this)
            GlobalState.launch { notifications.install() }
        } else stopSelf()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val promoted = promoteServiceForeground()
        if (promoted) BackendForegroundHold.created(this)
        if (intent?.action == BackendForegroundHold.ACTION_HOLD) {
            BackendForegroundHold.acknowledge(intent.getStringExtra("operationId"), promoted)
            return START_NOT_STICKY
        }
        if (intent?.action == BackendForegroundHold.ACTION_RUNTIME) {
            BackendForegroundHold.acknowledgeRuntime(intent.getStringExtra("operationId"), promoted)
            return if (promoted) START_STICKY else START_NOT_STICKY
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
            }.onFailure { GlobalState.log("host OS command failed: ${it.message}"); finishIfIdle() }
        }
        return if (ServiceStartCommand.sticky(method)) START_STICKY else START_NOT_STICKY
    }
    override fun onDestroy() {
        val lost = synchronized(resources) {
            destroyed = true
            active = false
            val owned = State.commonOwner.compareAndSet(this, null)
            if (owned) { State.runTime = 0L; State.clearAppliedVpnOptions() }
            owned
        }
        BackendForegroundHold.destroyed(this)
        runCatching { runBlocking { withTimeoutOrNull(3_000L) { notifications.uninstall() } } }
        if (lost) BackendOSObserver.service("service")
        super.onDestroy()
    }
    override suspend fun handleStart(options: VpnOptions) {
        check(BackendForegroundHold.isLive(this)) { "foreground host is stopping" }
        synchronized(resources) {
            check(!destroyed)
            active = true
            State.commonOwner.set(this)
            State.runTime = android.os.SystemClock.uptimeMillis()
        }
    }
    override suspend fun handleStop() {
        synchronized(resources) {
            active = false
            if (State.commonOwner.compareAndSet(this, null)) { State.runTime = 0L; State.clearAppliedVpnOptions() }
        }
        finishIfIdle()
    }
    override fun finishIfIdle() {
        BackendForegroundHold.retireIfIdle(this, { !active && State.runTime == 0L }) { stopSelfResult(lastStartId) }
    }
}
