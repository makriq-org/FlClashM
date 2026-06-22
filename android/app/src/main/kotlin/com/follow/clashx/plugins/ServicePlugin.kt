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
import android.util.Log
import androidx.core.app.NotificationCompat
import com.follow.clashx.GlobalState
import com.follow.clashx.RunState
import com.follow.clashx.Service
import com.follow.clashx.common.Components
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import com.follow.clashx.service.models.gsonSanitized
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.File

class ServicePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    CoroutineScope {
    companion object {
        private const val CHANNEL_NAMESPACE = "com.follow.clashx"
    }

    private var job = SupervisorJob()
    override val coroutineContext get() = job + Dispatchers.Main

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val eventChannel = Channel<String?>(Channel.UNLIMITED)
    private val gson = Gson()
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job = SupervisorJob()
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
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> handleInit(result)
            "shutdown" -> handleShutdown(result)
            "invokeAction" -> handleInvokeAction(call, result)
            "quickStart" -> handleQuickStart(call, result)
            "syncState" -> handleSyncState(call, result)
            "updateNotificationParams" -> handleUpdateNotificationParams(call, result)
            "start" -> handleStart(call, result)
            "stop" -> handleStop(result)
            "startVpn" -> handleStart(call, result)
            "stopVpn" -> handleStop(result)
            "getRunTime" -> handleGetRunTime(result)
            "startListener" -> launch { Service.startListener(); result.successOnMain(true) }
            "stopListener" -> launch { Service.stopListener(); result.successOnMain(true) }
            "setState" -> launch {
                val data = call.arguments<String>() ?: ""
                Service.setState(data)
                result.successOnMain(true)
            }
            "updateDns" -> launch {
                val data = call.arguments<String>() ?: ""
                Service.updateDns(data)
                result.successOnMain(true)
            }
            "getAndroidVpnOptions" -> launch { result.successOnMain(Service.getAndroidVpnOptions()) }
            "getCurrentProfileName" -> launch { result.successOnMain(Service.getCurrentProfileName()) }
            "getTraffic" -> launch { result.successOnMain(Service.getTraffic()) }
            "getTotalTraffic" -> launch { result.successOnMain(Service.getTotalTraffic()) }
            "startRuntimeNode" -> handleStartRuntimeNode(call, result)
            "stopRuntimeNode" -> launch {
                val nodeId = call.argument<String>("nodeId") ?: ""
                Service.stopRuntimeNode(nodeId)
                result.successOnMain(true)
            }
            "getRuntimeNodeRunTime" -> launch {
                val nodeId = call.argument<String>("nodeId") ?: ""
                result.successOnMain(Service.getRuntimeNodeRunTime(nodeId))
            }
            "resolveNativeRuntimeLibrary" -> {
                val name = call.argument<String>("name") ?: ""
                val file = File(context.applicationInfo.nativeLibraryDir, name)
                result.successOnMain(if (name.isNotBlank() && file.exists()) file.absolutePath else "")
            }
            "clearQuickStartParams" -> {
                com.follow.clashx.common.SavedParams.clearQuickStartParams()
                result.successOnMain(true)
            }
            "saveRuntimeNodesState" -> {
                val args = call.arguments as? Map<*, *>
                val nodes = args?.get("nodes") as? String ?: ""
                com.follow.clashx.common.SavedParams.saveRuntimeNodesState(nodes)
                result.successOnMain(true)
            }
            "clearRuntimeNodesState" -> {
                com.follow.clashx.common.SavedParams.clearRuntimeNodesState()
                result.successOnMain(true)
            }
            "showSubscriptionNotification" -> handleShowSubscriptionNotification(call, result)
            "saveParams" -> {
                val args = call.arguments as? Map<*, *>
                val init = args?.get("init") as? String ?: ""
                val params = args?.get("params") as? String ?: ""
                val state = args?.get("state") as? String ?: ""
                com.follow.clashx.common.SavedParams.saveQuickStartParams(init, params, state)
                result.successOnMain(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleInit(result: MethodChannel.Result) {
        runCatching { Service.bind() }.onFailure {
            Log.w("ServicePlugin", "Service.bind() failed: ${it.message}")
        }
        Service.onServiceDisconnected = ::onServiceDisconnected
        launch {
            Service.setEventListener { value -> dispatchEvent(value) }
                .onSuccess { result.successOnMain("") }
                .onFailure {
                    Log.w("ServicePlugin", "setEventListener failed: ${it.message}")
                    result.successOnMain("")
                }
        }
    }

    private fun handleShutdown(result: MethodChannel.Result) {
        launch { Service.setEventListener(null) }
        Service.unbind()
        result.successOnMain(true)
    }

    private fun onServiceDisconnected(message: String) {
        Log.w("ServicePlugin", "remote service disconnected: $message")
        // A RemoteService binder drop means the IPC bridge (the :remote process) was
        // recycled — NOT that the tunnel died. FlVpnService is START_STICKY + foreground
        // and recovers itself via coldStart as long as the persistent isVpnActive flag
        // stays set. Clearing that flag / forcing STOP here was exactly what dropped the
        // VPN on some phones when the app was reopened from background: the disconnect
        // queued while :main was frozen fired on resume and sabotaged the sticky recovery
        // (coldStart then saw isVpnActive == false and stopped itself). Instead, re-derive
        // the real state from the flag + an AIDL probe — handleSyncState keeps START while
        // the tunnel is genuinely up and only reports STOP when the flag is actually clear.
        // Genuine teardowns are still covered by the SERVICE_DESTROYED broadcast + the
        // explicit stop path. The "crash" signal makes Dart re-bind and re-register its
        // event listener against the reconnected service.
        CommonGlobalState.launch { GlobalState.handleSyncState() }
        invokeOnMain("crash", message)
    }

    private fun handleInvokeAction(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments<String>() ?: run { result.successOnMain(""); return }
        launch {
            Service.invokeAction(data) { payload -> result.successOnMain(payload) }
                .onFailure {
                    Log.w("ServicePlugin", "invokeAction failed: ${it.message}")
                    result.successOnMain("")
                }
        }
    }

    private fun handleQuickStart(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val initParams = args?.get("init") as? String ?: ""
        val params = args?.get("params") as? String ?: ""
        val state = args?.get("state") as? String ?: ""
        launch {
            Service.quickStart(
                initParams,
                params,
                state,
                onStarted = { invokeOnMain("onStarted", null) },
                onResult = { payload -> result.successOnMain(payload) },
            ).onFailure {
                Log.w("ServicePlugin", "quickStart failed: ${it.message}")
                result.successOnMain("")
            }
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val json = call.argument<String>("data") ?: call.arguments as? String
        val options = try {
            if (json.isNullOrBlank()) VpnOptions() else gson.fromJson(json, VpnOptions::class.java).gsonSanitized()
        } catch (e: Exception) {
            Log.w("ServicePlugin", "VpnOptions parse failed, using defaults: ${e.message}")
            VpnOptions()
        }
        if (options.enable && GlobalState.runStateFlow.value != RunState.START) {
            val plugin = GlobalState.getCurrentAppPlugin()
            if (plugin != null) {
                plugin.requestVpnPermission { granted ->
                    if (granted) {
                        doStartService(options, result)
                    } else {
                        // User denied/cancelled the VPN consent dialog: resolve the
                        // pending Flutter call with rt=0 instead of leaving it hanging.
                        com.follow.clashx.common.SavedParams.setVpnActive(false)
                        GlobalState.runStateFlow.tryEmit(RunState.STOP)
                        result.successOnMain(0L)
                    }
                }
            } else {
                doStartService(options, result)
            }
        } else {
            doStartService(options, result)
        }
    }

    private fun handleStartRuntimeNode(call: MethodCall, result: MethodChannel.Result) {
        val nodeId = call.argument<String>("nodeId") ?: ""
        val path = call.argument<String>("path") ?: ""
        val workingDirectory = call.argument<String>("workingDirectory") ?: ""
        val arguments = call.argument<List<String>>("arguments") ?: emptyList()
        if (nodeId.isBlank() || path.isBlank() || workingDirectory.isBlank()) {
            result.successOnMain(0L)
            return
        }
        launch {
            val runTime = Service.startRuntimeNode(nodeId, path, workingDirectory, arguments)
            result.successOnMain(runTime)
        }
    }

    private fun doStartService(options: VpnOptions, result: MethodChannel.Result) {
        launch {
            if (options.enable) {
                // Arm the late-SERVICE_DESTROYED guard at the real start moment so a
                // stale DESTROYED broadcast (e.g. delivered after :app unfreezes)
                // can't tear down this fresh tunnel. Covers in-app and tile-with-engine
                // starts, which bypass GlobalState.triggerStart's own arming.
                GlobalState.startRequestedAt = android.os.SystemClock.elapsedRealtime()
            }
            val rt = Service.startService(options, GlobalState.runTime)
            GlobalState.runTime = rt
            if (rt == 0L) {
                com.follow.clashx.common.SavedParams.setVpnActive(false)
            } else {
                GlobalState.getCurrentAppPlugin()?.requestNotificationsPermission()
                GlobalState.requestBatteryOptimizationExemption()
            }
            GlobalState.runStateFlow.tryEmit(if (rt == 0L) RunState.STOP else RunState.START)
            result.successOnMain(rt)
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        launch {
            runCatching { Service.stopService() }
                .onFailure { Log.w("ServicePlugin", "stopService failed: ${it.message}") }
            GlobalState.runTime = 0L
            com.follow.clashx.common.SavedParams.setVpnActive(false)
            GlobalState.runStateFlow.tryEmit(RunState.STOP)
            result.successOnMain(true)
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
        CommonGlobalState.log("updateNotificationParams: raw=$json")
        val params = try {
            gson.fromJson(json, NotificationParams::class.java) ?: NotificationParams()
        } catch (_: Exception) {
            NotificationParams()
        }
        CommonGlobalState.log("updateNotificationParams: title=${params.title}")
        launch {
            runCatching { Service.updateNotificationParams(params) }
                .onFailure { Log.w("ServicePlugin", "updateNotificationParams failed: ${it.message}") }
            result.successOnMain(true)
        }
    }

    private fun handleSyncState(call: MethodCall, result: MethodChannel.Result) {
        launch {
            val stateJson = call.arguments<String>() ?: ""
            if (stateJson.isNotBlank()) {
                Service.setState(stateJson)
            }
            GlobalState.handleSyncState()
            result.successOnMain("")
        }
    }

    private fun handleShowSubscriptionNotification(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run { result.successOnMain(false); return }
        val title = args["title"] as? String ?: ""
        val message = args["message"] as? String ?: ""
        val actionLabel = args["actionLabel"] as? String ?: ""
        val actionUrl = args["actionUrl"] as? String ?: ""

        val ctx = CommonGlobalState.application
        val manager = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(GlobalState.SUBSCRIPTION_NOTIFICATION_CHANNEL) == null) {
                val ch = NotificationChannel(
                    GlobalState.SUBSCRIPTION_NOTIFICATION_CHANNEL,
                    ctx.getString(com.follow.clashx.common.R.string.subscription_notification_channel_name),
                    NotificationManager.IMPORTANCE_HIGH,
                )
                manager.createNotificationChannel(ch)
            }
        }

        val builder = NotificationCompat.Builder(ctx, GlobalState.SUBSCRIPTION_NOTIFICATION_CHANNEL)
            .setSmallIcon(com.follow.clashx.service.R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(message)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        if (actionUrl.isNotBlank()) {
            val openIntent = Intent(Intent.ACTION_VIEW, Uri.parse(actionUrl))
            val pi = PendingIntent.getActivity(
                ctx, 0, openIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(
                0,
                actionLabel.ifBlank {
                    ctx.getString(com.follow.clashx.common.R.string.notification_open)
                },
                pi,
            )
            builder.setContentIntent(pi)
        }

        manager.notify(GlobalState.SUBSCRIPTION_NOTIFICATION_ID, builder.build())
        result.successOnMain(true)
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
}
