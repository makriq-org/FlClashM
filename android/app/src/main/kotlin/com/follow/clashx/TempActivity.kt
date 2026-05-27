package com.follow.clashx

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import com.follow.clashx.extensions.wrapAction

class TempActivity : Activity() {

    companion object {
        private const val TAG = "TempActivity"
        private const val VPN_REQUEST_CODE = 1001
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            wrapAction("START") -> {
                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null) {
                    Log.d(TAG, "Requesting VPN permission")
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    Log.d(TAG, "VPN permission already granted")
                    GlobalState.handleStart()
                    finishAndRemoveTask()
                }
            }
            wrapAction("STOP") -> {
                GlobalState.handleStop()
                finishAndRemoveTask()
            }
            wrapAction("CHANGE") -> {
                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null && GlobalState.runStateFlow.value != RunState.START) {
                    Log.d(TAG, "Toggle needs VPN permission first")
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    GlobalState.handleToggle()
                    finishAndRemoveTask()
                }
            }
            else -> finishAndRemoveTask()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                Log.d(TAG, "VPN permission granted, starting")
                GlobalState.handleStart()
            } else {
                Log.d(TAG, "VPN permission denied")
            }
            finishAndRemoveTask()
        }
    }
}
