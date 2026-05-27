package com.follow.clashx.service.modules

import android.app.Service
import com.follow.clashx.common.GlobalState
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.Module
import com.follow.clashx.service.State
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

class HealthCheckModule(service: Service) : Module(service) {
    private var periodicJob: Job? = null
    private val checkLock = Mutex()

    @Volatile
    private var consecutiveFailures = 0

    override suspend fun install() {
        periodicJob?.cancel()
        consecutiveFailures = 0
        periodicJob = GlobalState.launch {
            while (true) {
                delay(INTERVAL_MS)
                runCheck("periodic")
            }
        }
    }

    override suspend fun uninstall() {
        periodicJob?.cancel()
        periodicJob = null
        consecutiveFailures = 0
    }

    suspend fun runCheck(reason: String) {
        if (State.runTime == 0L) return
        checkLock.withLock {
            val ok = runCatching {
                withTimeoutOrNull(CHECK_TIMEOUT_MS) {
                    suspendCancellableCoroutine { cont ->
                        val action = """{"id":"hc_${System.currentTimeMillis()}","method":"healthCheck","data":""}"""
                        Core.invokeAction(action, object : InvokeInterface {
                            override fun onResult(result: String) {
                                if (cont.isActive) cont.resume(true)
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
        private const val INTERVAL_MS = 20 * 60 * 1000L
        private const val CHECK_TIMEOUT_MS = 30_000L
    }
}
