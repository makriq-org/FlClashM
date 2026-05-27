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
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

class ServicePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    CoroutineScope {

    private var job = SupervisorJob()
    override val coroutineContext get() = job + Dispatchers.Main

    private lateinit var channel: MethodChannel
    private val eventSemaphore = Semaphore(10)
    private val gson = Gson()
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        job = SupervisorJob()
        channel = MethodChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/service")
        channel.setMethodCallHandler(this)
        attached = true
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
        com.follow.clashx.common.SavedParams.setVpnActive(false)
        CommonGlobalState.launch {
            GlobalState.runLock.withLock {
                GlobalState.runTime = 0L
                GlobalState.runStateFlow.tryEmit(RunState.STOP)
            }
        }
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
            GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
                doStartService(options, result)
            } ?: doStartService(options, result)
        } else {
            doStartService(options, result)
        }
    }

    private fun doStartService(options: VpnOptions, result: MethodChannel.Result) {
        launch {
            val rt = Service.startService(options, GlobalState.runTime)
            GlobalState.runTime = rt
            if (rt == 0L) {
                com.follow.clashx.common.SavedParams.setVpnActive(false)
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
                    "Subscription Updates",
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
            builder.addAction(0, actionLabel.ifBlank { "Open" }, pi)
            builder.setContentIntent(pi)
        }

        manager.notify(GlobalState.SUBSCRIPTION_NOTIFICATION_ID, builder.build())
        result.successOnMain(true)
    }

    private fun dispatchEvent(value: String?) {
        CommonGlobalState.launch {
            eventSemaphore.withPermit {
                invokeOnMain("event", value)
            }
        }
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
