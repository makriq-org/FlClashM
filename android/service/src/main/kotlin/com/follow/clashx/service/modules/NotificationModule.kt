package com.follow.clashx.service.modules

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.buildServiceNotification
import com.follow.clashx.common.promoteToForeground
import com.follow.clashx.common.startForegroundSafely
import com.follow.clashx.service.Module
import com.follow.clashx.service.State
import com.follow.clashx.service.models.NotificationParams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Both foreground services share one notification ID. Every post goes through
 * this record so a content change is re-posted once, not once per service, and
 * the posted content is always the current one rather than a placeholder.
 */
internal class SharedNotificationContent(private val current: () -> NotificationParams) {
    private var posted: NotificationParams? = null

    /** Posts the current content. [force] is for startForeground, which the
     * platform requires on every start command even when nothing changed. */
    @Synchronized
    fun post(force: Boolean, show: (NotificationParams) -> Boolean): Boolean {
        val params = current()
        if (!force && params == posted) return false
        if (!show(params)) return false
        posted = params
        return true
    }
}

internal val serviceNotification = SharedNotificationContent { State.notificationParamsFlow.value }

/** Foreground promotion with the current shared content (never a placeholder title). */
internal fun Service.promoteServiceForeground(): Boolean = serviceNotification.post(force = true) { params ->
    promoteToForeground(com.follow.clashx.service.R.drawable.ic_notification, params.title, params.stopText)
}

class NotificationModule(service: Service) : Module(service) {
    private val lifecycle = Mutex()
    private var closed = false
    private var scope = CoroutineScope(SupervisorJob())
    private var paramsJob: Job? = null

    override suspend fun install() = lifecycle.withLock {
        if (closed) return@withLock
        scope = CoroutineScope(SupervisorJob())
        ensureChannel()
        val fgType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        serviceNotification.post(force = true) { params ->
            service.startForegroundSafely(GlobalState.NOTIFICATION_ID, buildNotification(params.title, params.stopText), fgType)
        }

        paramsJob = scope.launch {
            State.notificationParamsFlow.collectLatest {
                // The other service may have posted this content already.
                serviceNotification.post(force = false) { params ->
                    val manager = ContextCompat.getSystemService(service, NotificationManager::class.java)
                    manager?.notify(GlobalState.NOTIFICATION_ID, buildNotification(params.title, params.stopText))
                    manager != null
                }
            }
        }
    }

    override suspend fun uninstall() = lifecycle.withLock {
        closed = true
        paramsJob?.cancel()
        scope.cancel()
        if (State.runTime != 0L) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) service.stopForeground(Service.STOP_FOREGROUND_DETACH)
            else { @Suppress("DEPRECATION") service.stopForeground(false) }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(GlobalState.NOTIFICATION_CHANNEL) != null) return
        val channel = NotificationChannel(
            GlobalState.NOTIFICATION_CHANNEL,
            service.getString(com.follow.clashx.common.R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, stopText: String = ""): android.app.Notification {
        return service.buildServiceNotification(
            com.follow.clashx.service.R.drawable.ic_notification,
            title,
            stopText,
        )
    }
}
