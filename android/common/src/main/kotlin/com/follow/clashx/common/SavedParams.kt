package com.follow.clashx.common

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

object SavedParams {
    private const val PARAMS_FILE = "flclashx_always_on.json"
    private const val ACTIVE_FILE = "flclashx_vpn_active"
    private const val NOTIF_TITLE_FILE = "flclashx_notif_title"
    private const val START_TIME_FILE = "flclashx_start_time"
    private const val CRASHLYTICS_OPTOUT_FILE = "flclashx_crashlytics_optout"

    private val paramsFile by lazy { File(GlobalState.application.filesDir, PARAMS_FILE) }
    private val activeFile by lazy { File(GlobalState.application.filesDir, ACTIVE_FILE) }
    private val notifTitleFile by lazy { File(GlobalState.application.filesDir, NOTIF_TITLE_FILE) }
    private val startTimeFile by lazy { File(GlobalState.application.filesDir, START_TIME_FILE) }
    private val crashlyticsOptOutFile by lazy { File(GlobalState.application.filesDir, CRASHLYTICS_OPTOUT_FILE) }

    data class QuickStartParams(val init: String, val setup: String, val state: String)

    fun saveQuickStartParams(initParams: String, setupParams: String, stateParams: String) {
        runCatching {
            val json = JSONObject().apply {
                put("init", initParams)
                put("setup", setupParams)
                put("state", stateParams)
            }
            writeAtomic(paramsFile, json.toString())
        }.onFailure { GlobalState.log("saveQuickStartParams error: ${it.message}") }
    }

    fun loadQuickStartParams(): QuickStartParams? {
        if (!paramsFile.exists()) return null
        val text = runCatching { paramsFile.readText() }.getOrNull()
        if (text.isNullOrBlank()) {
            GlobalState.log("loadQuickStartParams: file empty or unreadable, clearing")
            runCatching { paramsFile.delete() }
            setVpnActive(false)
            return null
        }
        return runCatching {
            val json = JSONObject(text)
            val init = json.optString("init", "")
            val setup = json.optString("setup", "")
            val state = json.optString("state", "")
            if (init.isBlank() || setup.isBlank()) {
                setVpnActive(false)
                null
            } else QuickStartParams(init, setup, state)
        }.getOrElse {
            GlobalState.log("loadQuickStartParams error: ${it.message}")
            setVpnActive(false)
            null
        }
    }

    fun setVpnActive(active: Boolean) {
        GlobalState.crashKey("vpn_active", active.toString())
        runCatching {
            if (active) {
                activeFile.writeText("1")
            } else {
                activeFile.delete()
                clearStartTime()
            }
        }.onFailure { GlobalState.log("setVpnActive($active) error: ${it.message}") }
    }

    fun isVpnActive(): Boolean = activeFile.exists()

    // Marker file encodes opt-OUT so that a fresh install (no data at all)
    // means "enabled" — the default is on.
    fun setCrashlyticsEnabled(enable: Boolean) {
        runCatching {
            if (enable) {
                crashlyticsOptOutFile.delete()
            } else {
                crashlyticsOptOutFile.writeText("1")
            }
        }.onFailure { GlobalState.log("setCrashlyticsEnabled($enable) error: ${it.message}") }
    }

    fun isCrashlyticsEnabled(): Boolean = !crashlyticsOptOutFile.exists()

    // Persisted tunnel start timestamp (epoch ms). Lets a freshly-restarted UI process
    // recover the real uptime — and confirm the tunnel is up — when the AIDL runtime
    // probe isn't ready yet, instead of reading 0 and stopping the live VPN.
    fun setStartTime(ms: Long) {
        runCatching { writeAtomic(startTimeFile, ms.toString()) }
            .onFailure { GlobalState.log("setStartTime error: ${it.message}") }
    }

    fun getStartTime(): Long? =
        runCatching { startTimeFile.readText().trim().toLongOrNull() }.getOrNull()

    fun clearStartTime() {
        runCatching { if (startTimeFile.exists()) startTimeFile.delete() }
            .onFailure { GlobalState.log("clearStartTime error: ${it.message}") }
    }

    fun saveNotificationTitle(title: String) {
        runCatching { writeAtomic(notifTitleFile, title) }
            .onFailure { GlobalState.log("saveNotificationTitle error: ${it.message}") }
    }

    // ifBlank as well: an existing-but-empty file reads back "" without throwing,
    // which would render a blank notification title.
    fun loadNotificationTitle(): String =
        runCatching { notifTitleFile.readText().trim() }.getOrDefault("").ifBlank { "FlClashX" }

    private fun writeAtomic(target: File, content: String) {
        // Unique per-writer temp name: saveQuickStartParams runs in BOTH the :app and
        // :remote processes, so a fixed "<name>.tmp" lets concurrent writers stomp the
        // same temp and produce torn JSON. The rename to the target stays atomic.
        val tmp = File(target.parentFile, "${target.name}.${java.util.UUID.randomUUID()}.tmp")
        FileOutputStream(tmp).use {
            it.write(content.toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
        if (!tmp.renameTo(target)) {
            tmp.delete()
            // Surface the loss: every caller wraps writeAtomic in runCatching+log, so
            // throwing turns a silently dropped write into a visible log line.
            error("atomic rename to ${target.name} failed")
        }
    }
}
