package com.follow.clashx.plugins

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.follow.clashx.common.diagnostics.DiagnosticLog
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class DiagnosticsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.makriq.flclash/diagnostics",
        ).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "prepareSnapshot") {
            result.notImplemented()
            return
        }
        val appContext = context
        val currentChannel = channel
        if (appContext == null || currentChannel == null) {
            result.error("diagnostics_unavailable", "Diagnostics bridge is detached.", null)
            return
        }
        Thread {
            val outcome = runCatching {
                val remoteRequested = DiagnosticLog.requestOtherProcessesFlush(appContext)
                val localComplete = DiagnosticLog.flushBlocking()
                mapOf(
                    "directory" to File(appContext.filesDir, "diagnostics").absolutePath,
                    "api" to Build.VERSION.SDK_INT,
                    "abis" to Build.SUPPORTED_ABIS.toList(),
                    "localFlushComplete" to localComplete,
                    "remoteFlushRequested" to remoteRequested,
                )
            }
            mainHandler.post {
                if (channel !== currentChannel) return@post
                outcome.fold(
                    onSuccess = result::success,
                    onFailure = {
                        result.error(
                            "diagnostics_snapshot_failed",
                            "Could not prepare the diagnostic snapshot.",
                            null,
                        )
                    },
                )
            }
        }.apply {
            isDaemon = true
            name = "diagnostic-export-snapshot"
        }.start()
    }
}
