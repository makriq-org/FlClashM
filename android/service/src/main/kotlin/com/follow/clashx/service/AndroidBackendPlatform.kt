package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.ServiceDelegate
import com.follow.clashx.core.Core
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.models.gsonSanitized
import com.google.gson.Gson
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Android resource ownership only. All runtime intent and policy live in Go. */
internal object AndroidBackendPlatform {
    const val ACTION_APPLY = "com.makriq.flclash.backend.APPLY"
    private val lock = Mutex()

    suspend fun start(request: String) = lock.withLock {
        val context = GlobalState.application
        val options = Gson().fromJson(Core.getAndroidVpnOptions(), VpnOptions::class.java).gsonSanitized()
        if (options.enable) check(VpnService.prepare(context) == null) { "VPN permission is required" }
        coroutineContext.ensureActive()
        val serviceClass: Class<out Service> = if (options.enable) FlVpnService::class.java else CommonService::class.java
        val intent = Intent(context, serviceClass).setAction(ACTION_APPLY)
        val delegate = ServiceDelegate<IBaseService>(intent, onDisconnected = {}) { binder ->
            when (binder) {
                is FlVpnService.LocalBinder -> binder.service
                is CommonService.LocalBinder -> binder.service
                else -> null
            }
        }
        try {
            check(State.delegate == null) { "platform resources were not released" }
            State.delegate = delegate
            ContextCompat.startForegroundService(context, intent)
            delegate.bind()
            delegate.useService(timeoutMillis = 30_000L) { service ->
                coroutineContext.ensureActive()
                service.handleStart(options)
            }.getOrThrow()
            coroutineContext.ensureActive()
            State.runTime = SystemClock.uptimeMillis()
        } catch (error: Throwable) {
            withContext(NonCancellable) { stopLocked() }
            throw error
        }
    }

    suspend fun stop() = lock.withLock { stopLocked() }

    private suspend fun stopLocked() {
        val delegate = State.delegate
        if (delegate != null) {
            try { delegate.useService(timeoutMillis = 15_000L) { it.handleStop() }.getOrThrow() }
            finally { delegate.unbind(); State.delegate = null }
        } else if (State.tunOwner.get() != null) {
            State.tunOwner.get()?.handleStop()
        }
        Core.stopTun()
        State.runTime = 0L
        State.clearAppliedVpnOptions()
    }
}
