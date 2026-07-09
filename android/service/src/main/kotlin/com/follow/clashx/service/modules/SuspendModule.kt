package com.follow.clashx.service.modules

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.registerReceiverCompat
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.FlVpnService
import com.follow.clashx.service.Module

/**
 * Battery profile for the tunnel's PARTIAL_WAKE_LOCK. The lock blocks the SoC from
 * suspending, so it must NOT be held across standby. We hold it only while the screen
 * is on, plus a short grace window after screen-off (so a transfer started just before
 * locking isn't cut instantly), then release so the CPU can deep-sleep.
 *
 * The previous gate held the lock until *deep* Doze (isDeviceIdleMode). Deep Doze needs
 * the device stationary for a long ramp and the significant-motion sensor resets it, so
 * a phone carried in a pocket essentially never reaches it — the lock stayed held for
 * the entire screen-off window, the classic standby-drain anti-pattern. Releasing on
 * screen-off (with grace) is the real no-permanent-wakelock profile; idle proxied
 * connections that drop during sleep are re-established on wake (reconnectIfNeeded +
 * NetworkObserveModule's network-change reset). Deep/light Doze still force an early
 * release if they fire before the grace window elapses.
 */
class SuspendModule(
    service: Service,
    private val healthCheck: HealthCheckModule? = null,
) : Module(service) {

    private val vpn = service as? FlVpnService
    private val handler = Handler(Looper.getMainLooper())
    private val releaseLock = Runnable { vpn?.setAwake(false) }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON -> {
                    awakeNow()
                    // Resume config-interval provider health checks and, if they went
                    // dormant while dark, force an immediate catch-up sweep so
                    // fallback/url-test groups realign right at unlock.
                    pushScreenState(true)
                    // The periodic probe is suppressed while the screen is off; if a
                    // cycle was missed, verify the tunnel now so an overnight wedge
                    // is repaired by the time the user unlocks.
                    healthCheck?.scheduleCatchUpCheck()
                }
                Intent.ACTION_SCREEN_OFF -> {
                    // Stop provider health checks immediately (the wakelock grace
                    // below is only about in-flight transfers, not polling).
                    pushScreenState(false)
                    releaseAfterGrace()
                }
                // A Doze transition (deep or light): release immediately, sooner than
                // the grace window, so standby drain stops as early as possible.
                else -> if (isDozing()) {
                    pushScreenState(false)
                    releaseImmediately()
                }
            }
        }
    }

    // Mirrors the screen state into the core: it gates the provider toucher so
    // lazy provider/group health checks run at their config interval while the
    // device is in use (even with the UI backgrounded/killed) and go silent in
    // the dark. See handleSetScreenActive in core/hub.go.
    private fun pushScreenState(active: Boolean) {
        runCatching {
            val action =
                """{"id":"ss_${System.currentTimeMillis()}","method":"setScreenActive","data":$active}"""
            Core.invokeAction(action, object : InvokeInterface {
                override fun onResult(result: String) {}
            })
        }.onFailure { GlobalState.log("setScreenActive failed: ${it.message}") }
    }

    private fun isScreenOn(): Boolean {
        val pm = service.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return pm.isInteractive
    }

    // Deep Doze, or (API 33+) light Doze — both mean the system wants the CPU idle.
    private fun isDozing(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val pm = service.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        if (pm.isDeviceIdleMode) return true
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && pm.isDeviceLightIdleMode
    }

    private fun awakeNow() {
        handler.removeCallbacks(releaseLock)
        vpn?.setAwake(true)
    }

    private fun releaseImmediately() {
        handler.removeCallbacks(releaseLock)
        vpn?.setAwake(false)
    }

    // Keep the lock for SCREEN_OFF_GRACE_MS, then release so the CPU can suspend.
    private fun releaseAfterGrace() {
        vpn?.setAwake(true)
        handler.removeCallbacks(releaseLock)
        handler.postDelayed(releaseLock, SCREEN_OFF_GRACE_MS)
    }

    override suspend fun install() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                addAction(PowerManager.ACTION_DEVICE_LIGHT_IDLE_MODE_CHANGED)
            }
        }
        runCatching { service.registerReceiverCompat(receiver, filter) }
            .onFailure { GlobalState.log("SuspendModule register failed: ${it.message}") }
        // Evaluate the initial state on the main looper so it's serialized with the
        // broadcast callbacks (install() may run off the main thread).
        handler.post {
            when {
                isScreenOn() -> awakeNow()
                isDozing() -> releaseImmediately()
                else -> releaseAfterGrace()
            }
            // The core defaults screenActive=true on init; assert the real state so
            // a start while the screen is off doesn't keep touching providers.
            pushScreenState(isScreenOn())
        }
    }

    override suspend fun uninstall() {
        handler.removeCallbacks(releaseLock)
        runCatching { service.unregisterReceiver(receiver) }
    }

    companion object {
        // Grace after screen-off before releasing the wakelock (covers a transfer
        // started just before locking). ~2 min preserves essentially the whole
        // standby win for a phone left in a pocket.
        private const val SCREEN_OFF_GRACE_MS = 120_000L
    }
}
