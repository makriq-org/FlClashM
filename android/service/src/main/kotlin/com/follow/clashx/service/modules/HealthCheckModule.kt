package com.follow.clashx.service.modules

import android.app.Service
import com.follow.clashx.common.GlobalState
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.Module
import com.follow.clashx.service.State
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

class HealthCheckModule(service: Service) : Module(service) {
    // Dedicated scope so both the periodic loop AND network-triggered checks are
    // cancelled the instant the module is uninstalled (service stop), releasing
    // checkLock / the InvokeInterface callback instead of lingering on the
    // process-wide scope for up to CHECK_TIMEOUT_MS.
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var periodicJob: Job? = null
    private val checkLock = Mutex()

    @Volatile
    private var consecutiveFailures = 0

    // elapsedRealtime of the last network-triggered probe, used to debounce bursts
    // of network events. The periodic backstop is never throttled by this.
    @Volatile
    private var lastNetworkCheckAt = 0L

    override suspend fun install() {
        runCatching { scope.cancel() }
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        consecutiveFailures = 0
        lastNetworkCheckAt = 0L
        periodicJob = scope.launch {
            while (true) {
                delay(INTERVAL_MS)
                runCheck("periodic")
            }
        }
    }

    override suspend fun uninstall() {
        runCatching { scope.cancel() }
        periodicJob = null
        consecutiveFailures = 0
    }

    /**
     * Network-triggered one-shot probe on the module's own scope (cancelled on
     * uninstall), debounced so a flapping link can't fire back-to-back probes.
     * The periodic backstop (runCheck("periodic")) is intentionally not throttled.
     */
    fun scheduleCheck(reason: String) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastNetworkCheckAt < NETWORK_DEBOUNCE_MS) {
            return
        }
        lastNetworkCheckAt = now
        scope.launch { runCheck(reason) }
    }

    suspend fun runCheck(reason: String) {
        if (State.runTime == 0L) return
        checkLock.withLock {
            val ok = runCatching {
                withTimeoutOrNull(CHECK_TIMEOUT_MS) {
                    suspendCancellableCoroutine { cont ->
                        // Lightweight liveness probe: ONE generate_204 through the
                        // currently-selected outbound, NOT a full all-proxy URL-test
                        // sweep of every group (that woke the radio to ping the whole
                        // node list every cycle). The core wraps results in a JSON
                        // envelope, so "ok" lives in the "data" field.
                        val action = """{"id":"hp_${System.currentTimeMillis()}","method":"healthProbe","data":""}"""
                        Core.invokeAction(action, object : InvokeInterface {
                            override fun onResult(result: String) {
                                if (cont.isActive) cont.resume(result.contains("\"data\":\"ok\""))
                            }
                        })
                    }
                }
            }.getOrNull()

            if (ok == true) {
                if (consecutiveFailures > 0) {
                    GlobalState.log("HealthCheck ($reason): recovered after $consecutiveFailures failures")
                }
                consecutiveFailures = 0
            } else {
                consecutiveFailures++
                GlobalState.log("HealthCheck ($reason): failed ($consecutiveFailures consecutive)")
                recover()
            }
        }
    }

    private fun recover() {
        GlobalState.log("HealthCheck: resetting connections (attempt $consecutiveFailures)")
        runCatching { Core.resetConnections() }
            .onFailure { GlobalState.log("HealthCheck: resetConnections failed: ${it.message}") }
    }

    companion object {
        // Backstop cadence only: network change/restore/validated events trigger
        // their own (debounced) checks, so the periodic loop can be infrequent.
        // Combined with the single-probe healthProbe this slashes screen-off radio/CPU.
        private const val INTERVAL_MS = 15 * 60 * 1000L
        private const val CHECK_TIMEOUT_MS = 30_000L
        private const val NETWORK_DEBOUNCE_MS = 45_000L
    }
}
