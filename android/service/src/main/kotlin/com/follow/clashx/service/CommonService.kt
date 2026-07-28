package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.SavedParams
import com.follow.clashx.common.promoteToForeground
import com.follow.clashx.service.models.VpnOptions
import kotlinx.coroutines.sync.withLock
import com.follow.clashx.service.modules.NetworkObserveModule
import com.follow.clashx.service.modules.NotificationModule

class CommonService : Service(), IBaseService {

    inner class LocalBinder : Binder() {
        val service: CommonService = this@CommonService
    }

    private val binder = LocalBinder()
    @Volatile override var destroyed = false

    private val loader = moduleLoader {
        install { NetworkObserveModule(it) }
        install(::NotificationModule)
    }

    override fun onCreate() {
        super.onCreate()
        GlobalState.lifecycle("CommonService created")
        startForegroundCompat()
        handleCreate()
    }

    private fun startForegroundCompat() {
        if (!promoteToForeground(R.drawable.ic_notification, SavedParams.loadNotificationTitle())) {
            GlobalState.log("CommonService: foreground promotion denied, stopping")
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForegroundService() requires startForeground() within ~5s on every
        // delivery — including a stop sent this way and a start landing on an
        // already-created instance (onCreate only promotes on first creation).
        // Promote here every time (idempotent) or the OS throws
        // ForegroundServiceDidNotStartInTimeException.
        if (!promoteToForeground(
                R.drawable.ic_notification,
                SavedParams.loadNotificationTitle(),
            )
        ) {
            GlobalState.log("CommonService: foreground promotion denied in onStartCommand, stopping")
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == "com.makriq.flclash.service.STOP") {
            GlobalState.launch { State.runLock.withLock { handleStop() } }
            return START_NOT_STICKY
        }
        // Proxy-only mode never persists a cold-start flag, so a STICKY recreate
        // would only resurrect an empty foreground notification over a dead core.
        // Don't auto-restart; the app re-establishes the core explicitly.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        GlobalState.lifecycle("CommonService destroying")
        runCatching { kotlinx.coroutines.runBlocking { kotlinx.coroutines.withTimeoutOrNull(3000L) { loader.stop() } } }
        handleDestroy()
        super.onDestroy()
    }

    override suspend fun handleStart(options: VpnOptions) {
        loader.start()
    }

    override suspend fun handleStop() {
        State.runTime = 0L
        State.clearAppliedVpnOptions()
        loader.stop()
        handleDestroy()
        stopSelf()
    }
}
