package com.follow.clashx.common

import android.app.Notification
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flow
import kotlin.reflect.KClass


val KClass<*>.intent: Intent
    get() = Intent().setClassName(Components.PACKAGE_NAME, java.name)


fun Context.registerReceiverCompat(
    receiver: BroadcastReceiver,
    filter: IntentFilter,
    permission: String? = null,
) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        registerReceiver(receiver, filter, permission, null, Context.RECEIVER_NOT_EXPORTED)
    } else {
        @Suppress("UnspecifiedRegisterReceiverFlag")
        registerReceiver(receiver, filter, permission, null)
    }
}

fun Context.receiveBroadcastFlow(vararg actions: String): Flow<Intent> = callbackFlow {
    val filter = IntentFilter().apply { actions.forEach { addAction(it) } }
    val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent != null) trySend(intent)
        }
    }
    registerReceiverCompat(receiver, filter, "${Components.PACKAGE_NAME}.permission.RECEIVE_BROADCASTS")
    awaitClose { runCatching { unregisterReceiver(receiver) } }
}

fun Context.sendInternalBroadcast(action: String) {
    sendBroadcast(
        Intent(action).setPackage(Components.PACKAGE_NAME),
        "${Components.PACKAGE_NAME}.permission.RECEIVE_BROADCASTS",
    )
}


fun Service.ensureNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val mgr = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
            as android.app.NotificationManager
        if (mgr.getNotificationChannel(GlobalState.NOTIFICATION_CHANNEL) == null) {
            mgr.createNotificationChannel(
                android.app.NotificationChannel(
                    GlobalState.NOTIFICATION_CHANNEL,
                    getString(R.string.notification_channel_name),
                    android.app.NotificationManager.IMPORTANCE_LOW,
                )
            )
        }
    }
}

fun Service.buildServiceNotification(iconRes: Int, title: String = "FlClashX"): android.app.Notification {
    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
    val contentIntent = if (launchIntent != null) {
        android.app.PendingIntent.getActivity(
            this, 0, launchIntent,
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
        )
    } else null
    val stopIntent = android.content.Intent(this, this::class.java)
        .setAction("com.follow.clashx.service.STOP")
    val piFlags = android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
    val stopPending = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        android.app.PendingIntent.getForegroundService(this, 1, stopIntent, piFlags)
    } else {
        android.app.PendingIntent.getService(this, 1, stopIntent, piFlags)
    }
    val stopLabel = getString(R.string.notification_stop)
    return androidx.core.app.NotificationCompat.Builder(this, GlobalState.NOTIFICATION_CHANNEL)
        .setSmallIcon(iconRes)
        .setContentTitle(title)
        .setOngoing(true)
        .setPriority(androidx.core.app.NotificationCompat.PRIORITY_LOW)
        .apply { if (contentIntent != null) setContentIntent(contentIntent) }
        .addAction(android.R.drawable.ic_media_pause, stopLabel, stopPending)
        .build()
}

fun Service.promoteToForeground(iconRes: Int, title: String = "FlClashX") {
    ensureNotificationChannel()
    val notification = buildServiceNotification(iconRes, title)
    val fgType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    } else 0
    startForeground(GlobalState.NOTIFICATION_ID, notification, fgType)
}

fun Service.startForeground(id: Int, notification: Notification, foregroundServiceType: Int = 0) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && foregroundServiceType != 0) {
        ServiceCompat.startForeground(this, id, notification, foregroundServiceType)
    } else {
        startForeground(id, notification)
    }
}


private const val SMALL_PAYLOAD = 100 * 1024
private const val CHUNK_64K = 64 * 1024
private const val CHUNK_128K = 128 * 1024
private const val CHUNK_256K = 256 * 1024
private const val SIZE_1M = 1024 * 1024
private const val SIZE_10M = 10 * 1024 * 1024

fun ByteArray.chunkedForAidl(): Sequence<ByteArray> = sequence {
    val total = size
    if (total <= SMALL_PAYLOAD) {
        yield(this@chunkedForAidl)
        return@sequence
    }
    val chunk = when {
        total <= SIZE_1M -> CHUNK_64K
        total <= SIZE_10M -> CHUNK_128K
        else -> CHUNK_256K
    }
    var offset = 0
    while (offset < total) {
        val end = (offset + chunk).coerceAtMost(total)
        yield(copyOfRange(offset, end))
        offset = end
    }
}

fun List<ByteArray>.formatString(charset: java.nio.charset.Charset = Charsets.UTF_8): String {
    val total = sumOf { it.size }
    val buf = ByteArray(total)
    var offset = 0
    for (part in this) {
        System.arraycopy(part, 0, buf, offset, part.size)
        offset += part.size
    }
    return String(buf, charset)
}

fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble() / 1024.0
    var i = 0
    while (value >= 1024 && i < units.size - 1) {
        value /= 1024.0
        i++
    }
    return String.format("%.2f %s", value, units[i])
}


fun tickerFlow(intervalMillis: Long, initialDelay: Long = 0L): Flow<Unit> = flow {
    if (initialDelay > 0) kotlinx.coroutines.delay(initialDelay)
    while (true) {
        emit(Unit)
        kotlinx.coroutines.delay(intervalMillis)
    }
}
