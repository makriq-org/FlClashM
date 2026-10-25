package com.follow.clashx.plugins

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.follow.clashx.GlobalState
import com.follow.clashx.Service
import com.follow.clashx.common.BoundedEventRelay
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.diagnostics.DiagnosticLog
import com.follow.clashx.service.models.NotificationParams
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

class ServicePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    CoroutineScope {
    companion object {
        private const val CHANNEL_NAMESPACE = "com.makriq.flclash"
    }

    private var job = SupervisorJob()
    override val coroutineContext get() = job + Dispatchers.Default

    private lateinit var messenger: BinaryMessenger
    private lateinit var channel: MethodChannel
    private lateinit var coreChannel: MethodChannel
    @Volatile private var utf8Events = false
    private lateinit var context: Context
    private var events: BoundedEventRelay<String?>? = null
    private val gson = Gson()
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job = SupervisorJob()
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        channel = MethodChannel(binding.binaryMessenger, "$CHANNEL_NAMESPACE/service")
        channel.setMethodCallHandler(this)
        coreChannel = MethodChannel(binding.binaryMessenger, "$CHANNEL_NAMESPACE/core",
            StandardMethodCodec.INSTANCE, binding.binaryMessenger.makeBackgroundTaskQueue())
        coreChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "invokeMethod", "invokeAction" -> handleInvokeAction(call, result, utf8 = true)
                else -> result.notImplemented()
            }
        }
        attached = true
        // Single FIFO consumer so events (logs/traffic/state) reach Flutter strictly in
        // order, instead of racing across a Semaphore-bounded parallel dispatch pool.
        events = BoundedEventRelay(this) { value ->
            val argument = if (utf8Events) value?.toByteArray(Charsets.UTF_8) else value
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("event", argument))
            // Encode outside main as well: observations may contain large lists.
            // Wait for the platform hop: posting a Handler task per event would
            // drain the bounded channel into an unbounded main-looper backlog.
            withContext(Dispatchers.Main) {
                suspendCancellableCoroutine<Unit> { delivery ->
                    if (!attached) delivery.resume(Unit)
                    else messenger.send("$CHANNEL_NAMESPACE/service", message) {
                        // A standard MethodChannel handler replies after processing
                        // the event. Keep one outstanding message even when Dart
                        // stalls; command replies and Stop use a separate path.
                        if (delivery.isActive) delivery.resume(Unit)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        coreChannel.setMethodCallHandler(null)
        job.cancel()
        events?.close()
        events = null
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
            "init" -> {
                utf8Events = (call.arguments as? Map<*, *>)?.get("eventEncoding") == "utf8"
                handleInit(result)
            }
            "shutdown" -> handleShutdown(result)
            "invokeAction" -> handleInvokeAction(call, result)
            "requestVpnPermission" -> {
                val plugin = GlobalState.getCurrentAppPlugin()
                val prepareVpn = {
                    if (android.net.VpnService.prepare(context) == null) result.successOnMain(true)
                    else plugin?.requestVpnPermission { result.successOnMain(it) }
                        ?: result.successOnMain(false)
                }
                // Android 17 restricts LAN access separately. Ask from a visible
                // Activity, but refusal must not prevent the internet VPN itself.
                if (plugin != null) plugin.requestLocalNetworkPermission { prepareVpn() }
                else prepareVpn()
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

    private fun handleInvokeAction(call: MethodCall, result: MethodChannel.Result, utf8: Boolean = false) {
        val data = call.arguments as? String ?: run {
            result.errorOnMain("INVALID_ARGUMENT", "Action envelope must be a JSON string", null)
            return
        }
        launch {
            // Service.invokeAction completes the callback exactly once (real result /
            // registration failure / watchdog), so don't also complete here.
            Service.invokeAction(data) { payload ->
                // Result is thread-safe. Encode large replies here, never in a
                // main Handler task (which would stall input and explicit Stop).
                runCatching { result.success(if (utf8) payload.toByteArray(Charsets.UTF_8) else payload) }
            }
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
        events?.offer(value)
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
