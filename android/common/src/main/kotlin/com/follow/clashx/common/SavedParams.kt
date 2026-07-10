package com.follow.clashx.common

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

object SavedParams {
    private const val PARAMS_FILE = "flclashm_always_on.json"
    private const val LEGACY_PARAMS_FILE = "flclashx_always_on.json"
    private const val RUNTIME_NODES_FILE = "flclashm_runtime_nodes.json"
    private const val LEGACY_RUNTIME_NODES_FILE = "flclashx_runtime_nodes.json"
    private const val ACTIVE_FILE = "flclashm_vpn_active"
    private const val LEGACY_ACTIVE_FILE = "flclashx_vpn_active"
    private const val NOTIF_TITLE_FILE = "flclashm_notif_title"
    private const val LEGACY_NOTIF_TITLE_FILE = "flclashx_notif_title"

    private val paramsFile by lazy { file(PARAMS_FILE) }
    private val legacyParamsFile by lazy { file(LEGACY_PARAMS_FILE) }
    private val runtimeNodesFile by lazy { file(RUNTIME_NODES_FILE) }
    private val legacyRuntimeNodesFile by lazy { file(LEGACY_RUNTIME_NODES_FILE) }
    private val activeFile by lazy { file(ACTIVE_FILE) }
    private val legacyActiveFile by lazy { file(LEGACY_ACTIVE_FILE) }
    private val notifTitleFile by lazy { file(NOTIF_TITLE_FILE) }
    private val legacyNotifTitleFile by lazy { file(LEGACY_NOTIF_TITLE_FILE) }
    private const val START_TIME_FILE = "flclashx_start_time"

    private val startTimeFile by lazy { File(GlobalState.application.filesDir, START_TIME_FILE) }

    data class QuickStartParams(val init: String, val setup: String, val state: String)

    fun saveQuickStartParams(initParams: String, setupParams: String, stateParams: String) {
        runCatching {
            val json = JSONObject().apply {
                put("init", initParams)
                put("setup", setupParams)
                put("state", stateParams)
            }
            writeAtomic(paramsFile, json.toString())
            legacyParamsFile.delete()
        }.onFailure { GlobalState.log("saveQuickStartParams error: ${it.message}") }
    }

    fun loadQuickStartParams(): QuickStartParams? {
        migrateIfNeeded(paramsFile, legacyParamsFile)
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
        runCatching {
            if (active) {
                activeFile.writeText("1")
                legacyActiveFile.delete()
            } else {
                activeFile.delete()
                legacyActiveFile.delete()
                clearStartTime()
            }
        }.onFailure { GlobalState.log("setVpnActive($active) error: ${it.message}") }
    }

    fun isVpnActive(): Boolean {
        migrateIfNeeded(activeFile, legacyActiveFile)
        return activeFile.exists()
    }

    fun clearQuickStartParams() {
        runCatching {
            paramsFile.delete()
            legacyParamsFile.delete()
            runtimeNodesFile.delete()
            legacyRuntimeNodesFile.delete()
            activeFile.delete()
            legacyActiveFile.delete()
        }.onFailure { GlobalState.log("clearQuickStartParams error: ${it.message}") }
    }

    fun saveRuntimeNodesState(nodesJson: String) {
        runCatching {
            writeAtomic(runtimeNodesFile, nodesJson)
            legacyRuntimeNodesFile.delete()
        }
            .onFailure { GlobalState.log("saveRuntimeNodesState error: ${it.message}") }
    }

    fun loadRuntimeNodesState(): String? {
        migrateIfNeeded(runtimeNodesFile, legacyRuntimeNodesFile)
        return runCatching { runtimeNodesFile.readText() }
            .getOrNull()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    fun clearRuntimeNodesState() {
        runCatching {
            runtimeNodesFile.delete()
            legacyRuntimeNodesFile.delete()
        }
            .onFailure { GlobalState.log("clearRuntimeNodesState error: ${it.message}") }
    }

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
        runCatching {
            writeAtomic(notifTitleFile, title)
            legacyNotifTitleFile.delete()
        }
            .onFailure { GlobalState.log("saveNotificationTitle error: ${it.message}") }
    }

    // ifBlank as well: an existing-but-empty file reads back "" without throwing,
    // which would render a blank notification title.
    fun loadNotificationTitle(): String {
        migrateIfNeeded(notifTitleFile, legacyNotifTitleFile)
        return runCatching { notifTitleFile.readText().trim() }
            .getOrDefault("")
            .ifBlank { "FlClashM" }
    }

    private fun file(name: String): File = File(GlobalState.application.filesDir, name)

    private fun migrateIfNeeded(target: File, legacy: File) {
        if (target.exists() || !legacy.exists()) return
        runCatching {
            writeAtomic(target, legacy.readText())
            legacy.delete()
        }.onFailure {
            GlobalState.log("migrateIfNeeded(${legacy.name} -> ${target.name}) error: ${it.message}")
        }
    }

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
