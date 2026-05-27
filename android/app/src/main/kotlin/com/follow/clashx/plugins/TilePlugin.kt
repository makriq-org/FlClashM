package com.follow.clashx.plugins

import android.util.Log
import com.follow.clashx.GlobalState
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class TilePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    enum class PendingAction { START, STOP }

    private lateinit var channel: MethodChannel
    @Volatile private var attached = false

    companion object {
        private const val TAG = "TilePlugin"

        @Volatile
        private var pendingAction: PendingAction? = null

        @Volatile
        private var pendingMode: String? = null

        fun setPendingAction(action: PendingAction) {
            Log.d(TAG, "setPendingAction: $action")
            pendingAction = action
        }

        fun setPendingMode(mode: String) {
            Log.d(TAG, "setPendingMode: $mode")
            pendingMode = mode
        }

        fun clearPendingAction() {
            pendingAction = null
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "tile")
        channel.setMethodCallHandler(this)
        attached = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
    }

    private fun safeInvoke(method: String, argument: Any? = null) {
        if (!attached) return
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            if (!attached) return@post
            runCatching { channel.invokeMethod(method, argument) }
        }
    }

    fun handleStart() = safeInvoke("start")

    fun handleStop() = safeInvoke("stop")

    fun handleChangeMode(mode: String) = safeInvoke("changeMode", mode)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "serviceReady" -> {
                handleServiceReady()
                result.success(null)
            }
            "updateTile" -> {
                GlobalState.syncStatus()
                result.success(null)
            }
            "updateMode" -> {
                (call.arguments as? String)?.let { GlobalState.currentMode.postValue(it) }
                result.success(null)
            }
            "updateGlobalModeEnabled" -> {
                val enabled = call.arguments as? Boolean ?: true
                GlobalState.globalModeEnabled.postValue(enabled)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleServiceReady() {
        Log.d(TAG, "serviceReady: pendingAction=$pendingAction, pendingMode=$pendingMode")
        pendingAction?.let {
            when (it) {
                PendingAction.START -> handleStart()
                PendingAction.STOP -> handleStop()
            }
            pendingAction = null
        }
        pendingMode?.let {
            handleChangeMode(it)
            pendingMode = null
        }
    }
}
