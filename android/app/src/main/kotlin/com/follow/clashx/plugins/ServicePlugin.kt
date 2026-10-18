package com.follow.clashx.plugins

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.follow.clashx.GlobalState
import com.follow.clashx.RunState
import com.follow.clashx.Service
import com.follow.clashx.common.Components
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.diagnostics.DiagnosticLog
import com.follow.clashx.service.models.NotificationParams
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

class ServicePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    CoroutineScope {
    companion object {
        private const val CHANNEL_NAMESPACE = "com.makriq.flclash"
    }

    private var job = SupervisorJob()
    override val coroutineContext get() = job + Dispatchers.Main

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var eventChannel = Channel<String?>(256, BufferOverflow.DROP_OLDEST)
    private val gson = Gson()
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job = SupervisorJob()
        eventChannel = Channel(256, BufferOverflow.DROP_OLDEST)
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "$CHANNEL_NAMESPACE/service")
        channel.setMethodCallHandler(this)
        attached = true
        // Single FIFO consumer so events (logs/traffic/state) reach Flutter strictly in
        // order, instead of racing across a Semaphore-bounded parallel dispatch pool.
        launch {
            for (value in eventChannel) {
                invokeOnMain("event", value)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        job.cancel()
        eventChannel.cancel()
        // The engine is gone, so nothing consumes events anymore — drop OUR remote
        // listener so a dead engine doesn't keep the cross-process pipe pumping into
        // an unconsumed channel. Owner-guarded: if a recreated activity's new engine
        // already registered its own listener, this is a no-op. Runs on the global
        // scope — the plugin's own job was cancelled above.
        CommonGlobalState.launch {
            Service.clearEventListener(this@ServicePlugin)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> handleInit(result)
            "shutdown" -> handleShutdown(result)
            "invokeAction" -> handleInvokeAction(call, result)
            "requestVpnPermission" -> {
                if (android.net.VpnService.prepare(context) == null) result.successOnMain(true)
                else GlobalState.getCurrentAppPlugin()?.requestVpnPermission { result.successOnMain(it) }
                    ?: result.successOnMain(false)
            }
            "syncState" -> launch { GlobalState.handleSyncState(); result.successOnMain(true) }
            "updateNotificationParams" -> handleUpdateNotificationParams(call, result)
            "getRunTime" -> handleGetRunTime(result)
            "getAndroidVpnOptions" -> launch { result.successOnMain(Service.getAndroidVpnOptions()) }
            "getAppliedAndroidVpnOptions" -> launch { result.successOnMain(Service.getAppliedAndroidVpnOptions()) }
            "getCurrentProfileName" -> launch { result.successOnMain(Service.getCurrentProfileName()) }
            "getTraffic" -> launch { result.successOnMain(Service.getTraffic()) }
            "getTotalTraffic" -> launch { result.successOnMain(Service.getTotalTraffic()) }
            else -> result.notImplemented()
        }
    }

    private fun handleInit(result: MethodChannel.Result) {
        runCatching { Service.bind() }.onFailure {
            DiagnosticLog.e("ServicePlugin", "Service.bind() failed: ${it.message}", it)
        }
        Service.onServiceDisconnected = ::onServiceDisconnected
        launch {
            Service.setEventListener({ value -> dispatchEvent(value) }, owner = this@ServicePlugin)
                .onSuccess { result.successOnMain("") }
                .onFailure {
                    DiagnosticLog.e(
                        "ServicePlugin",
                        "setEventListener failed: ${it.message}",
                        it,
                    )
                    // Report the failure to Dart instead of swallowing it. A false
                    // "init succeeded" leaves Dart's _initSucceeded=true with NO live
                    // event pipe (empty Logs/Connections/Traffic), and reconnectIfNeeded()
                    // then no-ops forever — fixable only by a full app kill. Surfacing the
                    // error makes _initSucceeded=false so the resume-time reconnectIfNeeded()
                    // re-binds and re-registers the listener.
                    result.errorOnMain(
                        "init_event_listener_failed",
                        it.message ?: "setEventListener failed",
                        null,
                    )
                }
        }
    }

    private fun handleShutdown(result: MethodChannel.Result) {
        launch {
            Service.setEventListener(null)
            Service.unbind()
            result.successOnMain(true)
        }
    }

    private fun onServiceDisconnected(message: String) {
        DiagnosticLog.w("ServicePlugin", "remote service disconnected: $message")
        // Reconnect IPC and project a fresh Go snapshot. This callback never
        // derives runtime intent from UI state or SharedPreferences.
        CommonGlobalState.launch { GlobalState.handleSyncState() }
        invokeOnMain("crash", message)
    }

    private fun handleInvokeAction(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments<String>() ?: run { result.successOnMain(""); return }
        launch {
            // Service.invokeAction completes the callback exactly once (real result /
            // registration failure / watchdog), so don't also complete here.
            Service.invokeAction(data) { payload -> result.successOnMain(payload) }
                .onFailure {
                    DiagnosticLog.e(
                        "ServicePlugin",
                        "invokeAction failed: ${it.message}",
                        it,
                    )
                }
        }
    }

    private fun handleGetRunTime(result: MethodChannel.Result) {
        launch {
            GlobalState.handleSyncState()
            result.successOnMain(GlobalState.runTime)
        }
    }

    private fun handleUpdateNotificationParams(call: MethodCall, result: MethodChannel.Result) {
        val json = call.arguments<String>() ?: ""
        // Don't log the raw JSON or title: the profile/service name is user data.
        val params = try {
            gson.fromJson(json, NotificationParams::class.java) ?: NotificationParams()
        } catch (_: Exception) {
            NotificationParams()
        }
        CommonGlobalState.log("updateNotificationParams: titleLen=${params.title?.length ?: 0}")
        launch {
            runCatching { Service.updateNotificationParams(params) }
                .onFailure {
                    DiagnosticLog.e(
                        "ServicePlugin",
                        "updateNotificationParams failed: ${it.message}",
                        it,
                    )
                }
            result.successOnMain(true)
        }
    }

    private fun dispatchEvent(value: String?) {
        eventChannel.trySend(value)
    }

    private fun invokeOnMain(method: String, argument: Any?) {
        if (!attached) return
        Handler(Looper.getMainLooper()).post {
            if (!attached) return@post
            runCatching { channel.invokeMethod(method, argument) }
        }
    }

    private fun MethodChannel.Result.successOnMain(value: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runCatching { success(value) }
        } else {
            Handler(Looper.getMainLooper()).post { runCatching { success(value) } }
        }
    }

    private fun MethodChannel.Result.errorOnMain(code: String, message: String?, details: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runCatching { error(code, message, details) }
        } else {
            Handler(Looper.getMainLooper()).post { runCatching { error(code, message, details) } }
        }
    }
}
