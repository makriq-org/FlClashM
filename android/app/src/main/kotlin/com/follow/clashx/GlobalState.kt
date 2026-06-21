package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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

    const val NOTIFICATION_CHANNEL = "FlClashM"
    const val SUBSCRIPTION_NOTIFICATION_CHANNEL = "FlClashM_Subscription"
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
                            com.follow.clashx.services.FlClashMTileService.requestUpdate(
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
                                // A late DESTROYED from a previous service instance can arrive
                                // after a fresh start. If a start was just requested and the VPN
                                // flag is active, the new instance is coming up — don't clobber it.
                                val recentStart =
                                    android.os.SystemClock.elapsedRealtime() - startRequestedAt < 15_000L
                                if (com.follow.clashx.common.SavedParams.isVpnActive() && recentStart) {
                                    Log.d(TAG, "SERVICE_DESTROYED ignored: fresh start in progress")
                                    return@withLock
                                }
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
            val recentStart = android.os.SystemClock.elapsedRealtime() - startRequestedAt < 15_000L
            if (!vpnActive) {
                runTime = 0L
                runStateFlow.tryEmit(RunState.STOP)
                return@withLock
            }
            if (!isSystemVpnActive(CommonGlobalState.application) && !recentStart) {
                com.follow.clashx.common.SavedParams.setVpnActive(false)
                runTime = 0L
                runStateFlow.tryEmit(RunState.STOP)
                return@withLock
            }
            runCatching {
                Service.bind()
                val rtStr = Service.getRunTimeString() // null => AIDL probe failed/timed out
                val rt = rtStr?.toLongOrNull() ?: 0L
                // isVpnActive() (the cross-process file) already established the tunnel
                // SHOULD be running. Only an authoritative successful probe (rtStr != null)
                // returning rt == 0 (and no recent start) may downgrade to STOP; a failed
                // probe must not flip the UI off while the tunnel is genuinely up.
                val state = when {
                    rtStr == null -> RunState.START
                    rt != 0L -> RunState.START
                    recentStart -> RunState.START
                    else -> RunState.STOP
                }
                if (rtStr != null) runTime = rt
                if (state == RunState.START) {
                    if (runTime != 0L) {
                        // Cache the authoritative start time so a fresh UI process can
                        // recover it when its own AIDL probe isn't ready yet.
                        com.follow.clashx.common.SavedParams.setStartTime(runTime)
                    } else {
                        // Tunnel is up but we have no runtime (fresh process, probe not
                        // ready). Report the cached start time (or now) so the UI re-attaches
                        // instead of reading 0, deciding "stopped", and killing the VPN.
                        runTime = com.follow.clashx.common.SavedParams.getStartTime()
                            ?: System.currentTimeMillis().also {
                                com.follow.clashx.common.SavedParams.setStartTime(it)
                            }
                    }
                }
                if (runStateFlow.value != state) runStateFlow.tryEmit(state)
            }.onFailure {
                Log.w(TAG, "syncState failed: ${it.message}")
                if (runTime == 0L) {
                    runTime = com.follow.clashx.common.SavedParams.getStartTime()
                        ?: System.currentTimeMillis().also {
                            com.follow.clashx.common.SavedParams.setStartTime(it)
                        }
                }
                if (runStateFlow.value != RunState.START) runStateFlow.tryEmit(RunState.START)
            }
        }
    }

    fun isSystemVpnActive(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val activeNetwork = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    /**
     * Reads the persisted clash mode ("rule"/"global"/"direct") straight from Flutter's
     * SharedPreferences so widgets render the correct mode even before the Flutter engine
     * has started (cold boot / always-on). Returns null if unavailable.
     */
    fun readPersistedMode(): String? {
        val prefs = CommonGlobalState.application
            .getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
        val configJson = prefs.getString("flutter.clash_config", null) ?: return null
        return try {
            org.json.JSONObject(configJson).optString("mode", "").ifBlank { null }
        } catch (e: Exception) {
            null
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
            runLock.withLock {
                // Decide start-vs-stop from the fast cross-process file flag (plus the
                // in-memory state) rather than a slow AIDL sync, so a headless START
                // fires the foreground service while the widget/tile FGS-start grant is
                // still valid (avoids ForegroundServiceStartNotAllowedException paths).
                val running = com.follow.clashx.common.SavedParams.isVpnActive() ||
                    runStateFlow.value == RunState.START
                if (running) triggerStop() else triggerStart()
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
            getCurrentAppPlugin()?.requestNotificationsPermission()
            requestBatteryOptimizationExemption()
        }.onFailure {
            Log.w(TAG, "Direct VPN start failed: ${it.message}")
            com.follow.clashx.common.SavedParams.setVpnActive(false)
            runStateFlow.tryEmit(RunState.STOP)
            TilePlugin.setPendingAction(TilePlugin.PendingAction.START)
            launchMainActivity()
        }
    }

    private suspend fun triggerStop() {
        // Proceed if the cross-process flag says active even when the in-memory state
        // is a stale STOP (e.g. a headless cold-start the UI never observed).
        if (runStateFlow.value == RunState.STOP &&
            !com.follow.clashx.common.SavedParams.isVpnActive()) return

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

    private fun launchMainActivity() {
        val ctx = CommonGlobalState.application
        val intent = Intent(ctx, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        ctx.startActivity(intent)
    }
}
