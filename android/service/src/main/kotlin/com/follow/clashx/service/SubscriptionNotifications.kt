package com.follow.clashx.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject
import java.util.Locale

/** Localization/display mechanism. Go decides when and whether to send it. */
internal object SubscriptionNotifications {
    fun show(context: Context, notice: JSONObject): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        val language = notice.optString("locale")
        val localized = if (language.isBlank() || language == "system") context else {
            val config = Configuration(context.resources.configuration)
            config.setLocale(Locale.forLanguageTag(language.replace('_', '-')))
            context.createConfigurationContext(config)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = "FlClashM_Subscription"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) manager.createNotificationChannel(NotificationChannel(
            channel, localized.getString(com.follow.clashx.common.R.string.subscription_notification_channel_name), NotificationManager.IMPORTANCE_HIGH))
        val days = notice.getInt("days")
        val message = when {
            days < 0 -> localized.getString(com.follow.clashx.common.R.string.subscription_expired)
            days == 0 -> localized.getString(com.follow.clashx.common.R.string.subscription_expires_today)
            else -> localized.getString(com.follow.clashx.common.R.string.subscription_expires_in_days, days.toString())
        }
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle(notice.getString("title"))
            .setContentText(message).setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_HIGH)
        val support = notice.optString("supportUrl")
        if (support.isNotBlank()) {
            val action = PendingIntent.getActivity(context, 0, Intent(Intent.ACTION_VIEW, Uri.parse(support)), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.setContentIntent(action).addAction(0, localized.getString(com.follow.clashx.common.R.string.subscription_renew), action)
        }
        manager.notify(2, builder.build())
        return true
    }
}
