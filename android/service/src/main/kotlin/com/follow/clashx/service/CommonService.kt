package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import com.follow.clashx.common.GlobalState
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
        startForegroundCompat()
        handleCreate()
    }

    private fun startForegroundCompat() {
        promoteToForeground(R.drawable.ic_notification)
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "com.follow.clashx.service.STOP") {
            GlobalState.launch { State.runLock.withLock { handleStop() } }
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        runCatching { kotlinx.coroutines.runBlocking { kotlinx.coroutines.withTimeoutOrNull(3000L) { loader.stop() } } }
        handleDestroy()
        super.onDestroy()
    }

    override suspend fun handleStart(options: VpnOptions) {
        loader.start()
    }

    override suspend fun handleStop() {
        State.runTime = 0L
        loader.stop()
        handleDestroy()
        stopSelf()
    }
}
