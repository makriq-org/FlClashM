package com.follow.clashx.plugins

import android.os.Build
import android.os.Handler
import android.os.Looper
import com.follow.clashx.common.diagnostics.DiagnosticLog
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class DiagnosticsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "diagnostic-export-snapshot").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.makriq.flclash/diagnostics",
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "prepareSnapshot") {
            result.notImplemented()
            return
        }
        executor.execute {
            val context = binding.applicationContext
            DiagnosticLog.requestAllProcessesFlush(context)
            Thread.sleep(200L)
            DiagnosticLog.flushBlocking()
            val payload = mapOf(
                "directory" to File(context.filesDir, "diagnostics").absolutePath,
                "api" to Build.VERSION.SDK_INT,
                "abis" to Build.SUPPORTED_ABIS.toList(),
            )
            mainHandler.post { result.success(payload) }
        }
    }
}
