package com.follow.clashx

import android.content.Context
import android.content.Intent
import androidx.lifecycle.MutableLiveData
import com.follow.clashx.common.diagnostics.DiagnosticLog
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.extensions.getActionIntent
import com.follow.clashx.plugins.AppPlugin
import com.follow.clashx.plugins.TilePlugin
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
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

    @Volatile private var pendingTimeoutJob: Job? = null

    // seq of the last applied StateHub snapshot (guarded by runLock): an older
    // snapshot — e.g. a pull that was fetched before a transition but applied
    // after its push — is dropped instead of regressing the state.
    private var lastAppliedSeq: Long = 0L


    fun install() {
        CommonGlobalState.launch {
            runStateFlow.collect { state ->
                withContext(Dispatchers.Main) {
                    runState.value = state
                    if (state != RunState.PENDING) {
                        pendingTimeoutJob?.cancel()
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
        // Run-state arrives as StateHub pushes from :remote (registration delivers
        // a snapshot, then every transition). Replaces the SERVICE_CREATED/
        // DESTROYED broadcasts together with their late-delivery discriminators —
        // ordering is now guaranteed by the hub's seq instead of guessed from
        // timing windows.
        CommonGlobalState.launch {
            Service.remoteStateFlow.collect { snap ->
                if (snap == null) return@collect
                runLock.withLock { applyRemoteState(snap, notifyDart = true) }
            }
        }
    }

    /** Caller must hold [runLock]. Maps a StateHub snapshot onto the UI state. */
    private fun applyRemoteState(snap: Service.RemoteState, notifyDart: Boolean) {
        if (snap.seq < lastAppliedSeq) return
        lastAppliedSeq = snap.seq
        val state = when {
            snap.isStarting -> RunState.PENDING
            snap.isRunning -> RunState.START
            else -> RunState.STOP
        }
        runTime = if (state == RunState.START) snap.startedAt else 0L
        if (runStateFlow.value != state) {
            runStateFlow.tryEmit(state)
            // Externally-driven teardown (notification Stop, revoke, OS kill)
            // while the Flutter engine is up: tell Dart so its timers/UI stop too
            // — the contract the old SERVICE_DESTROYED handler provided. Push-path
            // only: pull-syncs must not re-trigger Dart's stop flow.
            if (notifyDart && state == RunState.STOP) {
                getCurrentTilePlugin()?.handleStop()
            }
        }
    }


    fun getCurrentAppPlugin(): AppPlugin? =
        flutterEngine?.plugins?.get(AppPlugin::class.java) as? AppPlugin

    fun getCurrentTilePlugin(): TilePlugin? =
        flutterEngine?.plugins?.get(TilePlugin::class.java) as? TilePlugin

    fun syncStatus() {
        CommonGlobalState.launch { handleSyncState() }
    }

    suspend fun handleSyncState() {
        runLock.withLock {
            Service.bind()
            val snap = Service.fetchServiceState()
            if (snap != null) {
                // StateHub owns the truth (including the recovery bias for a fresh
                // :remote whose sticky cold-start hasn't run yet); just apply it.
                applyRemoteState(snap, notifyDart = false)
                return@withLock
            }
            // :remote unreachable (bind warming up / wedged): fall back to the
            // persisted intent flag. A failed probe must not flip a live tunnel's
            // UI to off — the flag-holder recovers via sticky/boot cold-start.
            DiagnosticLog.w(TAG, "syncState: remote unreachable, deriving from intent flag")
            if (com.follow.clashx.common.SavedParams.isVpnActive()) {
                if (runTime == 0L) {
                    runTime = com.follow.clashx.common.SavedParams.getStartTime()
                        ?: System.currentTimeMillis()
                }
                if (runStateFlow.value != RunState.START) runStateFlow.tryEmit(RunState.START)
            } else {
                runTime = 0L
                if (runStateFlow.value != RunState.STOP) runStateFlow.tryEmit(RunState.STOP)
            }
        }
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
            DiagnosticLog.e(TAG, "hasActiveProfile parse error: ${e.message}", e)
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
        DiagnosticLog.d(TAG, "handleChangeMode: $mode")
        currentMode.postValue(mode)
        // Headless limitation: the clash mode lives in ClashConfig and only reaches the
        // core through setupConfig/updateConfig (a full Dart-built config patch), NOT
        // through the AIDL state path (Service.setState -> RemoteService.setState ->
        // Core.setState) — the CoreState payload carries vpn-props/profile-name/bypass
        // only, no mode field. So with no Flutter engine there is no clean way to apply
        // the mode headlessly; we stash it as pendingMode and apply it when the app next
        // opens (widgets may visually revert until then). Reusing setState for the mode
        // would require extending the CoreState contract on both Dart and Go sides.
        getCurrentTilePlugin()?.handleChangeMode(mode)
            ?: run { TilePlugin.setPendingMode(mode) }
    }

    private fun schedulePendingTimeout() {
        pendingTimeoutJob?.cancel()
        pendingTimeoutJob = CommonGlobalState.launch {
            delay(15_000L)
            if (runStateFlow.value != RunState.PENDING) return@launch
            DiagnosticLog.w(TAG, "PENDING timeout: Dart-delegated start unconfirmed")
            // The Dart side never confirmed the start (engine busy/mid-teardown/
            // lost channel). Instead of only re-syncing (which leaves the tile stuck
            // then reverting to OFF), fall back to a headless start from saved params
            // so the tunnel still comes up. If consent is needed or no params exist,
            // headless gracefully degrades to launching the activity / syncing.
            val hasSaved = com.follow.clashx.common.SavedParams.loadQuickStartParams() != null
            if (hasSaved && !com.follow.clashx.common.SavedParams.isVpnActive()) {
                runLock.withLock {
                    if (runStateFlow.value == RunState.PENDING) startHeadlessFromSaved()
                }
            } else {
                handleSyncState()
            }
        }
    }

    /** Caller MUST hold [runLock]. Brings the tunnel up headlessly from the
     *  persisted cold-start params, degrading to consent/activity launch when
     *  VPN permission isn't yet granted. */
    private suspend fun startHeadlessFromSaved() {
        val ctx = CommonGlobalState.application
        val vpnPrepare = android.net.VpnService.prepare(ctx)
        if (vpnPrepare != null) {
            DiagnosticLog.d(TAG, "startHeadlessFromSaved: VPN permission needed")
            runStateFlow.tryEmit(RunState.STOP)
            TilePlugin.setPendingAction(TilePlugin.PendingAction.START)
            launchMainActivity()
            return
        }
        com.follow.clashx.common.SavedParams.setVpnActive(true)
        runCatching {
            val intent = android.content.Intent(ctx, com.follow.clashx.service.FlVpnService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(ctx, intent)
            runStateFlow.tryEmit(RunState.START)
        }.onFailure {
            DiagnosticLog.e(TAG, "startHeadlessFromSaved: start failed: ${it.message}", it)
            com.follow.clashx.common.SavedParams.setVpnActive(false)
            runStateFlow.tryEmit(RunState.STOP)
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
            DiagnosticLog.d(TAG, "triggerStart: VPN permission needed, launching TempActivity")
            runCatching {
                val tempIntent = ctx.getActionIntent("START")
                ctx.startActivity(tempIntent)
            }
            return
        }

        com.follow.clashx.common.SavedParams.setVpnActive(true)
        runCatching {
            val intent = android.content.Intent(ctx, com.follow.clashx.service.FlVpnService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(ctx, intent)
            runStateFlow.tryEmit(RunState.START)
        }.onFailure {
            DiagnosticLog.e(TAG, "Direct VPN start failed: ${it.message}", it)
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
