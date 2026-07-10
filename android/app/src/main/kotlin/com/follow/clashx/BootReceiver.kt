package com.follow.clashx

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.util.Log
import com.follow.clashx.common.SavedParams

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val vpnActive = SavedParams.isVpnActive()
        val hasProfile = GlobalState.hasActiveProfile()
        Log.d(TAG, "BOOT_COMPLETED: vpnActive=$vpnActive hasProfile=$hasProfile")

        if (!vpnActive || !hasProfile) return

        if (isVpnAlreadyActive(context)) {
            Log.d(TAG, "VPN already active (system Always-On), skipping")
            return
        }

        val vpnPrepare = VpnService.prepare(context)
        if (vpnPrepare != null) {
            Log.d(TAG, "VPN permission not granted, clearing active state")
            SavedParams.setVpnActive(false)
            return
        }

        GlobalState.startRequestedAt = android.os.SystemClock.elapsedRealtime()
        GlobalState.runStateFlow.tryEmit(RunState.START)

        try {
            val serviceIntent = Intent(context, com.follow.clashx.service.FlVpnService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(context, serviceIntent)
            Log.d(TAG, "FlVpnService started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start FlVpnService: ${e.message}")
            GlobalState.runStateFlow.tryEmit(RunState.STOP)
        }
    }

    private fun isVpnAlreadyActive(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val activeNetwork = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }
}
