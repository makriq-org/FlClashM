package com.follow.clashx.services

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import androidx.lifecycle.Observer
import com.follow.clashx.GlobalState
import com.follow.clashx.RunState

@RequiresApi(Build.VERSION_CODES.N)
class FlClashMTileService : TileService() {

    companion object {
        fun requestUpdate(context: Context) {
            requestListeningState(
                context,
                ComponentName(context, FlClashMTileService::class.java),
            )
        }

        @Volatile
        private var lastClickTime: Long = 0L
        private const val DEBOUNCE_MS = 500L
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val syncRunnable = Runnable { syncTile() }

    // Debounce: collapse rapid successive runState changes into a single tile update
    // so the icon doesn't flicker when state briefly oscillates during start/stop.
    private fun syncTileDebounced() {
        mainHandler.removeCallbacks(syncRunnable)
        mainHandler.postDelayed(syncRunnable, 80L)
    }

    private val observer = Observer<RunState> { syncTileDebounced() }

    override fun onStartListening() {
        super.onStartListening()
        GlobalState.syncStatus()
        syncTile()
        GlobalState.runState.observeForever(observer)
    }

    override fun onStopListening() {
        mainHandler.removeCallbacks(syncRunnable)
        GlobalState.runState.removeObserver(observer)
        super.onStopListening()
    }

    override fun onClick() {
        val tile = qsTile ?: return
        if (GlobalState.runStateFlow.value == RunState.PENDING) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastClickTime < DEBOUNCE_MS) return
        lastClickTime = now

        when (tile.state) {
            Tile.STATE_INACTIVE -> {
                tile.state = Tile.STATE_ACTIVE
                tile.updateTile()
                // Don't force a screen unlock: unlockAndRun() prompts the lock screen.
                // With VPN permission already granted + saved cold-start params the start
                // is headless (startForegroundService, no activity), so the VPN toggles
                // straight from the locked Quick Settings panel — like happ / v2raytun.
                GlobalState.handleStart()
            }
            Tile.STATE_ACTIVE -> {
                tile.state = Tile.STATE_INACTIVE
                tile.updateTile()
                GlobalState.handleStop()
            }
        }
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(syncRunnable)
        GlobalState.runState.removeObserver(observer)
        super.onDestroy()
    }

    private fun syncTile() {
        val tile = qsTile ?: return
        tile.state = when {
            !GlobalState.hasActiveProfile() -> Tile.STATE_UNAVAILABLE
            GlobalState.runStateFlow.value == RunState.START -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.updateTile()
    }
}
