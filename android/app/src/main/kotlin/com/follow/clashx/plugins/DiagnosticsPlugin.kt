package com.follow.clashx.plugins

import android.os.Build
import android.os.Handler
import android.os.Looper
import com.follow.clashx.common.diagnostics.DiagnosticLog
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class DiagnosticsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var executor: ExecutorService? = null
    private var attachmentGeneration = 0L
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        attachmentGeneration++
        executor?.shutdownNow()
        executor = newExecutor()
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.makriq.flclash/diagnostics",
        ).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        this.binding = null
        attachmentGeneration++
        executor?.shutdownNow()
        executor = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "prepareSnapshot") {
            result.notImplemented()
            return
        }
        val currentBinding = binding
        val currentExecutor = executor
        val generation = attachmentGeneration
        if (currentBinding == null || currentExecutor == null) {
            result.error("diagnostics_unavailable", "Diagnostics bridge is detached.", null)
            return
        }
        try {
            currentExecutor.execute {
                val outcome = runCatching {
                    val context = currentBinding.applicationContext
                    val flushComplete = DiagnosticLog.requestAllProcessesFlush(context)
                    if (!flushComplete) DiagnosticLog.flushBlocking()
                    mapOf(
                        "directory" to
                            File(context.filesDir, "diagnostics").absolutePath,
                        "api" to Build.VERSION.SDK_INT,
                        "abis" to Build.SUPPORTED_ABIS.toList(),
                        "flushComplete" to flushComplete,
                    )
                }
                if (Thread.currentThread().isInterrupted) return@execute
                mainHandler.post {
                    if (
                        this.binding !== currentBinding ||
                        attachmentGeneration != generation
                    ) {
                        return@post
                    }
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
            }
        } catch (_: RejectedExecutionException) {
            result.error(
                "diagnostics_unavailable",
                "Diagnostics bridge is shutting down.",
                null,
            )
        }
    }

    private fun newExecutor(): ExecutorService =
        Executors.newSingleThreadExecutor { task ->
            Thread(task, "diagnostic-export-snapshot").apply { isDaemon = true }
        }
}
