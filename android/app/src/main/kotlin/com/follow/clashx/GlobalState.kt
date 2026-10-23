package com.follow.clashx

import android.content.Intent
import android.net.VpnService
import androidx.lifecycle.MutableLiveData
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.extensions.wrapAction
import com.follow.clashx.plugins.AppPlugin
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

enum class RunState { START, PENDING, STOP }

/** Main-process UI projection and user actions; durable intent lives in Go. */
object GlobalState {
    const val NOTIFICATION_CHANNEL = "FlClashM"
    const val SUBSCRIPTION_NOTIFICATION_CHANNEL = "FlClashM_Subscription"
    const val NOTIFICATION_ID = 1
    const val SUBSCRIPTION_NOTIFICATION_ID = 2
    val runState = MutableLiveData(RunState.STOP)
    val currentMode = MutableLiveData("rule")
    val globalModeEnabled = MutableLiveData(true)
    val runStateFlow = MutableStateFlow(RunState.STOP)
    val runLock = Mutex()
    @Volatile var runTime = 0L
    @Volatile var flutterEngine: FlutterEngine? = null
    @Volatile private var profileAvailable = false
    @Volatile private var requiresVpn = true
    @Volatile private var projectedMode = "rule"
    private var lastAppliedSeq = 0L

    fun install() {
        CommonGlobalState.launch {
            Service.remoteStateFlow.collect { snapshot ->
                if (snapshot != null) runLock.withLock { project(snapshot) }
            }
        }
        Service.bind()
    }
    private suspend fun project(snapshot: Service.RemoteState) {
        if (snapshot.seq < lastAppliedSeq) return
        lastAppliedSeq = snapshot.seq
        val state = when { snapshot.isRunning -> RunState.START; snapshot.isStarting -> RunState.PENDING; else -> RunState.STOP }
        runTime = if (snapshot.isRunning) snapshot.startedAt else 0L
        profileAvailable = snapshot.hasActiveProfile
        requiresVpn = snapshot.requiresVpn
        projectedMode = snapshot.mode
        if (snapshot.themeMode.isNotEmpty()) StartupTheme.store(CommonGlobalState.application, snapshot.themeMode)
        runStateFlow.value = state
        withContext(Dispatchers.Main) {
            runState.value = state
            currentMode.value = snapshot.mode
            globalModeEnabled.value = snapshot.globalModeEnabled
            runCatching { com.follow.clashx.services.FlClashMTileService.requestUpdate(CommonGlobalState.application) }
        }
    }
    fun getCurrentAppPlugin(): AppPlugin? = flutterEngine?.plugins?.get(AppPlugin::class.java) as? AppPlugin
    fun syncStatus() { CommonGlobalState.launch { handleSyncState() } }
    suspend fun handleSyncState() {
        Service.bind()
        val snapshot = Service.fetchServiceState() ?: return
        runLock.withLock { project(snapshot) }
    }
    fun readPersistedMode(): String = projectedMode
    fun hasActiveProfile(): Boolean = profileAvailable
    fun handleStart() = userCommand("runtime.start", permission = true)
    fun handleStop() = userCommand("runtime.stop")
    fun handleToggle() = userCommand("runtime.toggle", permission = true)
    fun handleChangeMode(mode: String) = userCommand("settings.patch", JSONObject().put("patch", JSONObject().put("patchClashConfig", JSONObject().put("mode", mode))))
    private fun userCommand(method: String, params: JSONObject = JSONObject(), permission: Boolean = false) {
        val context = CommonGlobalState.application
        if (permission && requiresVpn && VpnService.prepare(context) != null) {
            context.startActivity(Intent(context, TempActivity::class.java).setAction(context.wrapAction("START")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        CommonGlobalState.launch {
            runCatching { Service.backendCommand(method, params) }
                .onFailure { CommonGlobalState.log("backend user action failed: ${it.message}") }
            handleSyncState()
        }
    }
}
