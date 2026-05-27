package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.lifecycle.MutableLiveData
import com.follow.clashx.common.BroadcastAction
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.receiveBroadcastFlow
import com.follow.clashx.extensions.getActionIntent
import com.follow.clashx.plugins.AppPlugin
import com.follow.clashx.plugins.TilePlugin
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

enum class RunState { START, PENDING, STOP }

object GlobalState {
    private const val TAG = "GlobalState"

    const val NOTIFICATION_CHANNEL = "FlClashX"
    const val SUBSCRIPTION_NOTIFICATION_CHANNEL = "FlClashX_Subscription"
    const val NOTIFICATION_ID = 1
    const val SUBSCRIPTION_NOTIFICATION_ID = 2


    val runState: MutableLiveData<RunState> = MutableLiveData(RunState.STOP)
    val currentMode: MutableLiveData<String> = MutableLiveData("rule")
    val globalModeEnabled: MutableLiveData<Boolean> = MutableLiveData(true)


    val runStateFlow: MutableStateFlow<RunState> = MutableStateFlow(RunState.STOP)

    val runLock = Mutex()
    @Volatile var runTime: Long = 0L
    @Volatile var flutterEngine: FlutterEngine? = null
    @Volatile var startRequestedAt: Long = 0L

    private var broadcastJob: Job? = null
    private var pendingTimeoutJob: Job? = null


    fun install() {
        CommonGlobalState.launch {
            runStateFlow.collect { state ->
                withContext(Dispatchers.Main) {
                    runState.value = state
                    if (state != RunState.PENDING) {
                        pendingTimeoutJob?.cancel()
                    }
                    if (state != RunState.PENDING) {
                        runCatching {
                            com.follow.clashx.services.FlClashXTileService.requestUpdate(
                                CommonGlobalState.application,
                            )
                        }
                        runCatching {
                            val ctx = CommonGlobalState.application
                            val mgr = android.appwidget.AppWidgetManager.getInstance(ctx)
                            for (cls in arrayOf(
                                com.follow.clashx.widgets.OnOffWidgetProvider::class.java,
                                com.follow.clashx.widgets.ModeWidgetProvider::class.java,
                            )) {
                                val ids = mgr.getAppWidgetIds(android.content.ComponentName(ctx, cls))
                                if (ids.isNotEmpty()) {
                                    val intent = android.content.Intent(ctx, cls)
                                        .setAction(android.appwidget.AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                                        .putExtra(android.appwidget.AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                                    ctx.sendBroadcast(intent)
                                }
                            }
                        }
                    }
                }
            }
        }
        broadcastJob?.cancel()
        broadcastJob = CommonGlobalState.application
            .receiveBroadcastFlow(
                BroadcastAction.SERVICE_CREATED.action,
                BroadcastAction.SERVICE_DESTROYED.action,
            )
            .onEach { intent ->
                when (intent.action) {
                    BroadcastAction.SERVICE_CREATED.action -> {
                        Log.d(TAG, "SERVICE_CREATED received")
                        CommonGlobalState.launch { handleSyncState() }
                    }
                    BroadcastAction.SERVICE_DESTROYED.action -> {
                        Log.d(TAG, "SERVICE_DESTROYED received")
                        CommonGlobalState.launch {
                            runLock.withLock {
                                startRequestedAt = 0L
                                runTime = 0L
                                runStateFlow.tryEmit(RunState.STOP)
                                getCurrentTilePlugin()?.handleStop()
                            }
                        }
                    }
                }
            }
            .launchIn(CommonGlobalState.scope)
    }


    fun getCurrentAppPlugin(): AppPlugin? =
        flutterEngine?.plugins?.get(AppPlugin::class.java) as? AppPlugin

    fun getCurrentTilePlugin(): TilePlugin? =
        flutterEngine?.plugins?.get(TilePlugin::class.java) as? TilePlugin

    suspend fun getText(text: String): String =
        getCurrentAppPlugin()?.getText(text) ?: ""


    fun syncStatus() {
        CommonGlobalState.launch { handleSyncState() }
    }

    suspend fun handleSyncState() {
        runLock.withLock {
            val vpnActive = com.follow.clashx.common.SavedParams.isVpnActive()
            if (!vpnActive) {
                runTime = 0L
                runStateFlow.tryEmit(RunState.STOP)
                return@withLock
            }
            val recentStart = android.os.SystemClock.elapsedRealtime() - startRequestedAt < 15_000L
            runCatching {
                Service.bind()
                val rt = Service.getRunTimeString().toLongOrNull() ?: 0L
                runTime = rt
                val state = when {
                    rt != 0L -> RunState.START
                    recentStart -> RunState.START
                    else -> RunState.STOP
                }
                runStateFlow.tryEmit(state)
            }.onFailure {
                Log.w(TAG, "syncState failed: ${it.message}")
                if (!recentStart) {
                    runTime = 0L
                    runStateFlow.tryEmit(RunState.STOP)
                }
            }
        }
    }

    fun hasActiveProfile(): Boolean {
        val prefs = CommonGlobalState.application
            .getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
        val configJson = prefs.getString("flutter.config", null)
        if (configJson == null) return false
        return try {
            val currentProfileId = org.json.JSONObject(configJson).optString("currentProfileId", null)
            !currentProfileId.isNullOrEmpty()
        } catch (e: Exception) {
            Log.e(TAG, "hasActiveProfile parse error: ${e.message}")
            false
        }
    }


    fun handleToggle() {
        CommonGlobalState.launch {
            handleSyncState()
            runLock.withLock {
                when (runStateFlow.value) {
                    RunState.STOP, RunState.PENDING -> triggerStart()
                    RunState.START -> triggerStop()
                }
            }
        }
    }

    fun handleStart() {
        CommonGlobalState.launch {
            runLock.withLock { triggerStart() }
        }
    }

    fun handleStop() {
        CommonGlobalState.launch {
            runLock.withLock { triggerStop() }
        }
    }

    fun handleChangeMode(mode: String) {
        Log.d(TAG, "handleChangeMode: $mode")
        currentMode.postValue(mode)
        getCurrentTilePlugin()?.handleChangeMode(mode)
            ?: run { TilePlugin.setPendingMode(mode) }
    }

    private fun schedulePendingTimeout() {
        pendingTimeoutJob?.cancel()
        pendingTimeoutJob = CommonGlobalState.launch {
            delay(15_000L)
            if (runStateFlow.value == RunState.PENDING) {
                Log.w(TAG, "PENDING timeout, forcing sync")
                handleSyncState()
            }
        }
    }

    private suspend fun triggerStart() {
        if (runStateFlow.value == RunState.START) return

        val tile = getCurrentTilePlugin()
        if (tile != null) {
            runStateFlow.tryEmit(RunState.PENDING)
            tile.handleStart()
            schedulePendingTimeout()
            return
        }

        val hasSavedParams = com.follow.clashx.common.SavedParams.loadQuickStartParams() != null
        if (!hasSavedParams) {
            runStateFlow.tryEmit(RunState.STOP)
            TilePlugin.setPendingAction(TilePlugin.PendingAction.START)
            launchMainActivity()
            return
        }

        val ctx = CommonGlobalState.application
        val vpnPrepare = android.net.VpnService.prepare(ctx)
        if (vpnPrepare != null) {
            Log.d(TAG, "triggerStart: VPN permission needed, launching TempActivity")
            runCatching {
                val tempIntent = ctx.getActionIntent("START")
                ctx.startActivity(tempIntent)
            }
            return
        }

        com.follow.clashx.common.SavedParams.setVpnActive(true)
        startRequestedAt = android.os.SystemClock.elapsedRealtime()
        runCatching {
            val intent = android.content.Intent(ctx, com.follow.clashx.service.FlVpnService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(ctx, intent)
            runStateFlow.tryEmit(RunState.START)
        }.onFailure {
            Log.w(TAG, "Direct VPN start failed: ${it.message}")
            com.follow.clashx.common.SavedParams.setVpnActive(false)
            runStateFlow.tryEmit(RunState.STOP)
            TilePlugin.setPendingAction(TilePlugin.PendingAction.START)
            launchMainActivity()
        }
    }

    private suspend fun triggerStop() {
        if (runStateFlow.value == RunState.STOP) return

        startRequestedAt = 0L
        com.follow.clashx.common.SavedParams.setVpnActive(false)
        runTime = 0L
        runStateFlow.tryEmit(RunState.STOP)

        runCatching { getCurrentTilePlugin()?.handleStop() }

        runCatching {
            val ctx = CommonGlobalState.application
            val stopIntent = android.content.Intent(ctx, com.follow.clashx.service.FlVpnService::class.java)
                .setAction(com.follow.clashx.service.FlVpnService.ACTION_STOP)
            androidx.core.content.ContextCompat.startForegroundService(ctx, stopIntent)
        }
        CommonGlobalState.launch {
            runCatching { Service.stopListener() }
            runCatching { Service.stopService() }
        }
    }

    fun requestBatteryOptimizationExemption() {
        val ctx = CommonGlobalState.application
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) return
        runCatching {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${ctx.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
        }.onFailure {
            Log.w(TAG, "Failed to request battery optimization exemption: ${it.message}")
        }
    }

    private fun launchMainActivity() {
        val ctx = CommonGlobalState.application
        val intent = Intent(ctx, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        ctx.startActivity(intent)
    }
}
