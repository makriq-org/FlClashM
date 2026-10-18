package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.promoteToForeground
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.modules.NotificationModule
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/** Foreground resource for proxy-only execution. No runtime policy. */
class CommonService : Service(), BackendForegroundResource {
    inner class LocalBinder : Binder() { val service: CommonService = this@CommonService }
    private val binder = LocalBinder()
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
    override fun onBind(intent: Intent?): IBinder = binder
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!promoteToForeground(R.drawable.ic_notification, "FlClashM")) { stopSelf(); return START_NOT_STICKY }
        if (intent?.action != AndroidBackendPlatform.ACTION_APPLY) {
            GlobalState.launch { BackendHost.initialize(); BackendHost.command("runtime.recover") }
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        val lost = active
        active = false
        destroyed = true
        BackendForegroundHold.destroyed(this)
        runCatching { runBlocking { withTimeoutOrNull(3_000L) { notifications.uninstall() } } }
        if (lost) { State.runTime = 0L; BackendOSObserver.service("service") }
        super.onDestroy()
    }
    override suspend fun handleStart(options: VpnOptions) { check(!destroyed); active = true }
    override suspend fun handleStop() { active = false; State.runTime = 0L; State.clearAppliedVpnOptions(); finishIfIdle() }
    override fun finishIfIdle() { if (!active && !BackendForegroundHold.held) stopSelf() }
}
