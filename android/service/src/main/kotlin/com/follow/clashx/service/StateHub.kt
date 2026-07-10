package com.follow.clashx.service

import android.os.RemoteCallbackList
import android.os.SystemClock
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.SavedParams
import org.json.JSONObject

/**
 * Single owner of the VPN run-state. Every transition in the :remote process is
 * published here (and ONLY here reported outward); :main and Dart are pure
 * subscribers. Replaces the SERVICE_CREATED/SERVICE_DESTROYED broadcasts and the
 * pull-probe reconciliation heuristics that grew around them.
 *
 * Live publishes carry the raw truth of a transition. Snapshot reads (register
 * delivery / getServiceState) are recovery-aware instead: a fresh :remote process
 * starts as STOPPED even when the persisted intent flag says the tunnel should be
 * up and a sticky/boot cold-start simply hasn't run yet — reporting that raw
 * STOPPED made consumers treat a recovering tunnel as user-stopped (the old
 * "UI reads 0 and kills the live VPN" class of bugs). The bias mirrors the old
 * probe-failure behavior: show RUNNING; if recovery never comes, the first
 * toggle-off clears the flag and everything converges to STOPPED.
 */
object StateHub {
    const val STARTING = "starting"
    const val RUNNING = "running"
    const val STOPPING = "stopping"
    const val STOPPED = "stopped"

    private data class Snapshot(
        val state: String,
        val startedAt: Long,
        val message: String,
        // Publish moment on the device-wide monotonic clock. Consumers drop
        // snapshots older than the last applied one, so a pull that raced a
        // transition (fetched before, applied after) can't regress the state —
        // and unlike a per-process counter it stays monotonic across :remote
        // process restarts.
        val seq: Long,
    ) {
        fun toJson(): String = JSONObject()
            .put("state", state)
            .put("startedAt", startedAt)
            .put("message", message)
            .put("seq", seq)
            .toString()
    }

    private val callbacks = RemoteCallbackList<IStateCallback>()

    // One monitor for state mutation, registration and broadcast:
    // RemoteCallbackList.beginBroadcast() must never run concurrently, and a
    // register's snapshot delivery must not interleave with a publish, or a
    // client could observe transitions out of order.
    private val lock = Any()
    private var current = Snapshot(STOPPED, 0L, "", 0L)

    // Bound for the recovery bias below: a sticky/boot cold-start lands within
    // seconds of process start, so past this window a still-initial STOPPED means
    // no recovery is coming and the raw state is the truth.
    private const val RECOVERY_GRACE_MS = 30_000L
    private val processStartedAt = SystemClock.elapsedRealtime()

    fun publish(state: String, startedAt: Long = 0L, message: String = "") {
        synchronized(lock) {
            if (state == current.state && startedAt == current.startedAt) return
            val next = Snapshot(state, startedAt, message, SystemClock.elapsedRealtime())
            current = next
            GlobalState.log("StateHub: $state${if (message.isNotBlank()) " ($message)" else ""}")
            broadcastLocked(next.toJson())
        }
    }

    /** RUNNING with the tunnel start moment; also the single writer of the
     *  persisted start-time cache (was :main's handleSyncState). */
    fun publishRunning() {
        val startedAt = System.currentTimeMillis()
        SavedParams.setStartTime(startedAt)
        publish(RUNNING, startedAt)
    }

    fun register(callback: IStateCallback) {
        synchronized(lock) {
            callbacks.register(callback)
            // Immediate snapshot delivery doubles as the post-(re)connect state
            // sync. oneway — never blocks the service process.
            runCatching { callback.onStateChanged(effectiveSnapshotLocked().toJson()) }
        }
    }

    fun unregister(callback: IStateCallback) {
        synchronized(lock) { callbacks.unregister(callback) }
    }

    fun snapshotJson(): String = synchronized(lock) { effectiveSnapshotLocked().toJson() }

    private fun effectiveSnapshotLocked(): Snapshot {
        val cur = current
        // Bias only the initial state (seq == 0: no transition has happened in
        // this process yet) and only within the grace window — an old process
        // sitting at STOPPED with the flag still set means recovery never came
        // (e.g. OEM blocked the sticky restart), and reporting RUNNING forever
        // would pin a dead tunnel's UI to ON. Read-only: the stale flag itself
        // is cleared by the next explicit toggle-off, never by a snapshot read.
        if (cur.state == STOPPED && cur.seq == 0L &&
            SystemClock.elapsedRealtime() - processStartedAt < RECOVERY_GRACE_MS &&
            SavedParams.isVpnActive()
        ) {
            // Same seq as the underlying state: the bias is a view of it, and a
            // later real transition (larger seq) must still win at the consumer.
            return Snapshot(
                RUNNING,
                SavedParams.getStartTime() ?: System.currentTimeMillis(),
                "recovery-expected",
                cur.seq,
            )
        }
        return cur
    }

    private fun broadcastLocked(json: String) {
        val n = callbacks.beginBroadcast()
        try {
            for (i in 0 until n) {
                runCatching { callbacks.getBroadcastItem(i).onStateChanged(json) }
            }
        } finally {
            callbacks.finishBroadcast()
        }
    }
}
