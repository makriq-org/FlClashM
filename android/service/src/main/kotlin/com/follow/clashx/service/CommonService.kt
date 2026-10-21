package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.IBinder
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.promoteToForeground
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.modules.NotificationModule
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/** Foreground lifetime for backend operations and execution, independently of
 * the VPN system binding. Also provides the proxy-only platform resource. */
class CommonService : Service(), BackendForegroundResource {
    private val resources = Any()
    @Volatile override var destroyed = false
    @Volatile private var active = false
    private val notifications = NotificationModule(this)

    override fun onCreate() {
        super.onCreate()
        handleCreate()
        if (promoteToForeground(R.drawable.ic_notification, "FlClashM")) {
            BackendForegroundHold.created(this)
            GlobalState.launch { notifications.install() }
        } else stopSelf()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val promoted = promoteToForeground(R.drawable.ic_notification, "FlClashM")
        if (intent?.action == BackendForegroundHold.ACTION_HOLD) {
            BackendForegroundHold.acknowledge(intent.getStringExtra("operationId"), promoted)
            return START_NOT_STICKY
        }
        if (intent?.action == BackendForegroundHold.ACTION_RUNTIME) {
            BackendForegroundHold.acknowledgeRuntime(intent.getStringExtra("operationId"), promoted)
            return if (promoted) START_STICKY else START_NOT_STICKY
        }
        if (!promoted) { stopSelf(); return START_NOT_STICKY }
        if (intent?.action != AndroidBackendPlatform.ACTION_APPLY) {
            GlobalState.launch { BackendHost.initialize(); BackendHost.command("runtime.recover") }
        }
        return START_STICKY
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
    override fun finishIfIdle() { if (!active && State.runTime == 0L && !BackendForegroundHold.held) stopSelf() }
}
