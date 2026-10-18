package com.follow.clashx

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.follow.clashx.common.GlobalState
import com.follow.clashx.service.FlVpnService

/** OS wakeup only. Go recovery reads its committed journal and explicit stop. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON", "com.htc.intent.action.QUICKBOOT_POWERON" -> {
                runCatching { ContextCompat.startForegroundService(context, Intent(context, FlVpnService::class.java)) }
                    .onFailure { GlobalState.log("backend OS wake failed: ${it.message}") }
            }
        }
    }
}
