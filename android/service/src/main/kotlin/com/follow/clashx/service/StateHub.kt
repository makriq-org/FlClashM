package com.follow.clashx.service

import android.os.RemoteCallbackList
import android.os.SystemClock
import org.json.JSONObject

/** A Binder projection of Go snapshots, with no recovery or persisted intent. */
object StateHub {
    const val STARTING = "starting"
    const val RUNNING = "running"
    const val STOPPING = "stopping"
    const val STOPPED = "stopped"

    private val callbacks = RemoteCallbackList<IStateCallback>()
    private val lock = Any()
    private var state = STOPPED
    private var startedAt = 0L
    private var message = ""
    private var sequence = 0L
    private var mode = "rule"
    private var globalModeEnabled = true
    private var hasActiveProfile = false

    fun publish(value: String, startedAt: Long = 0L, message: String = "") = synchronized(lock) {
        if (state == value && this.startedAt == startedAt && this.message == message) return@synchronized
        state = value
        this.startedAt = startedAt
        this.message = message
        broadcastLocked()
    }

    fun projectPresentation(value: JSONObject) = synchronized(lock) {
        val nextMode = value.optString("mode", "rule")
        val nextGlobal = value.optBoolean("globalModeEnabled", true)
        val nextProfile = value.optBoolean("hasActiveProfile")
        if (mode == nextMode && globalModeEnabled == nextGlobal && hasActiveProfile == nextProfile) return@synchronized
        mode = nextMode; globalModeEnabled = nextGlobal; hasActiveProfile = nextProfile
        broadcastLocked()
    }

    private fun broadcastLocked() {
        sequence = maxOf(sequence + 1, SystemClock.elapsedRealtime())
        val json = snapshotLocked()
        val count = callbacks.beginBroadcast()
        try { for (index in 0 until count) runCatching { callbacks.getBroadcastItem(index).onStateChanged(json) } }
        finally { callbacks.finishBroadcast() }
    }

    fun register(callback: IStateCallback) = synchronized(lock) {
        callbacks.register(callback)
        runCatching { callback.onStateChanged(snapshotLocked()) }
        Unit
    }
    fun unregister(callback: IStateCallback) = synchronized(lock) { callbacks.unregister(callback); Unit }
    fun snapshotJson(): String = synchronized(lock) { snapshotLocked() }
    private fun snapshotLocked(): String = JSONObject().put("state", state).put("startedAt", startedAt)
        .put("message", message).put("seq", sequence).put("mode", mode)
        .put("globalModeEnabled", globalModeEnabled).put("hasActiveProfile", hasActiveProfile).toString()
}
