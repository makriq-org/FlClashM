package com.follow.clashx.service.modules

import android.app.Service
import android.content.Context
import android.os.PowerManager
import com.follow.clashx.common.GlobalState
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.Module
import com.follow.clashx.service.State
import kotlinx.coroutines.CancellationException
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
    // @Volatile: reassigned on install()'s coroutine thread but read from the
    // ConnectivityManager callback thread in scheduleCheck() — needs safe publication.
    @Volatile
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile
    private var periodicJob: Job? = null
    private val checkLock = Mutex()

    @Volatile
    private var consecutiveFailures = 0

    // elapsedRealtime of the last network-triggered probe, used to debounce bursts
    // of network events. The periodic backstop is never throttled by this.
    @Volatile
    private var lastNetworkCheckAt = 0L

    // Set when a periodic cycle was suppressed because the screen was off; consumed
    // by the screen-on catch-up (SuspendModule -> scheduleCatchUpCheck) so short
    // screen-off windows don't add a probe on every unlock.
    @Volatile
    private var missedPeriodicWhileDark = false

    override suspend fun install() {
        runCatching { scope.cancel() }
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        consecutiveFailures = 0
        lastNetworkCheckAt = 0L
        missedPeriodicWhileDark = false
        periodicJob = scope.launch {
            while (true) {
                delay(INTERVAL_MS)
                // Screen off / doze: skip the probe instead of waking the radio out
                // of idle (an RRC promotion per cycle — classic standby drain) for a
                // tunnel nobody is using. Recovery while dark still happens via the
                // network-change triggers; a wedge with NO network event is repaired
                // by the screen-on catch-up probe before the user starts browsing.
                if (!isInteractive()) {
                    missedPeriodicWhileDark = true
                    continue
                }
                runCheck("periodic")
            }
        }
    }

    override suspend fun uninstall() {
        runCatching { scope.cancel() }
        periodicJob = null
        consecutiveFailures = 0
        missedPeriodicWhileDark = false
    }

    private fun isInteractive(): Boolean {
        val pm = service.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return pm.isInteractive
    }

    /**
     * Screen-on catch-up: probe only when a periodic cycle was actually suppressed
     * while the screen was off — preserves the backstop's at-most-one-probe-per-
     * interval budget instead of probing on every unlock. Runs through
     * [scheduleCheck], so it shares the network debounce (a probe that just ran for
     * a network event makes the catch-up redundant anyway).
     */
    fun scheduleCatchUpCheck() {
        if (!missedPeriodicWhileDark) return
        missedPeriodicWhileDark = false
        scheduleCheck("screen-on")
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
            // Cancellation (service stop -> scope.cancel()) must propagate, not count
            // as a failed probe: swallowing it ran recover() -> resetConnections()
            // during teardown — and on a fast off->on that reset could land AFTER the
            // next start and cut the fresh tunnel's connections.
            val ok: Boolean? = try {
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
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }

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
        // their own (debounced) checks, so the periodic loop can be infrequent —
        // and it fires only while the device is interactive (see install()).
        // Combined with the single-probe healthProbe this slashes screen-off radio/CPU.
        private const val INTERVAL_MS = 15 * 60 * 1000L
        private const val CHECK_TIMEOUT_MS = 30_000L
        private const val NETWORK_DEBOUNCE_MS = 45_000L
    }
}
