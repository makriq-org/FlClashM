package com.follow.clashx.common

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

object SavedParams {
    private const val PARAMS_FILE = "flclashx_always_on.json"
    private const val ACTIVE_FILE = "flclashx_vpn_active"
    private const val NOTIF_TITLE_FILE = "flclashx_notif_title"

    private val paramsFile by lazy { File(GlobalState.application.filesDir, PARAMS_FILE) }
    private val activeFile by lazy { File(GlobalState.application.filesDir, ACTIVE_FILE) }
    private val notifTitleFile by lazy { File(GlobalState.application.filesDir, NOTIF_TITLE_FILE) }

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
        runCatching {
            if (active) activeFile.writeText("1") else activeFile.delete()
        }.onFailure { GlobalState.log("setVpnActive($active) error: ${it.message}") }
    }

    fun isVpnActive(): Boolean = activeFile.exists()

    fun saveNotificationTitle(title: String) {
        runCatching { writeAtomic(notifTitleFile, title) }
            .onFailure { GlobalState.log("saveNotificationTitle error: ${it.message}") }
    }

    fun loadNotificationTitle(): String =
        runCatching { notifTitleFile.readText().trim() }.getOrDefault("FlClashX")

    private fun writeAtomic(target: File, content: String) {
        val tmp = File(target.parentFile, "${target.name}.tmp")
        FileOutputStream(tmp).use {
            it.write(content.toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
        if (!tmp.renameTo(target)) {
            tmp.delete()
        }
    }
}
