package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import com.follow.clashx.common.GlobalState
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
    private var active: BackendForegroundResource? = null

    suspend fun start(request: String) = lock.withLock {
        val context = GlobalState.application
        val options = Gson().fromJson(Core.getAndroidVpnOptions(), VpnOptions::class.java).gsonSanitized()
        if (options.enable) check(VpnService.prepare(context) == null) { "VPN permission is required" }
        coroutineContext.ensureActive()
        val serviceClass: Class<out Service> = if (options.enable) FlVpnService::class.java else CommonService::class.java
        val intent = Intent(context, serviceClass).setAction(ACTION_APPLY)
        try {
            check(active == null) { "platform resources were not released" }
            ContextCompat.startForegroundService(context, intent)
            // Both objects live in :remote. Self-binding a service makes Android
            // unbind a dead client from itself during process cleanup, which can
            // remove the sticky service from the restart list before scheduling.
            val service = BackendForegroundHold.awaitService(serviceClass)
            active = service
            coroutineContext.ensureActive()
            service.handleStart(options)
            // A normal sticky host survives the system's VPN unbind when the
            // TUN disappears on process death. It has no separate runtime intent.
            BackendForegroundHold.retainRuntime(request)
            coroutineContext.ensureActive()
        } catch (error: Throwable) {
            withContext(NonCancellable) { stopLocked() }
            throw error
        }
    }

    suspend fun stop() = lock.withLock { stopLocked() }

    private suspend fun stopLocked() {
        val service = active
        active = null
        try {
            if (service != null) service.handleStop()
            else {
                State.tunOwner.get()?.handleStop()
                State.commonOwner.get()?.handleStop()
            }
        } finally {
            Core.stopTun()
            State.runTime = 0L
            State.clearAppliedVpnOptions()
            BackendForegroundHold.finishIdle()
        }
    }
}

/** Maps a service start that is not a resource handshake to the Go request it
 * forwards. Shared by both foreground services because the notification Stop
 * action targets whichever of them posted the notification last. */
internal object ServiceStartCommand {
    const val ACTION_STOP = "com.makriq.flclash.service.STOP"

    /** null: the start only delivers an Android resource to a Go operation. */
    fun backendMethod(action: String?): String? = when (action) {
        AndroidBackendPlatform.ACTION_APPLY,
        BackendForegroundHold.ACTION_HOLD,
        BackendForegroundHold.ACTION_RUNTIME -> null
        ACTION_STOP -> "runtime.stop"
        // Boot, sticky restart or an OS-created instance: Go decides what to recover.
        else -> "runtime.recover"
    }

    /** A Stop must not be redelivered by the OS after process death. */
    fun sticky(method: String): Boolean = method != "runtime.stop"
}
