package com.follow.clashx.common

import java.io.File

/** Read-only input to the one-time Go migration, never a recovery authority. */
object LegacyBackendMigration {
    fun wasRunning(): Boolean = listOf("flclashm_vpn_active", "flclashx_vpn_active")
        .any { File(GlobalState.application.filesDir, it).exists() }
    fun removeReplacedRuntimeState() {
        for (name in listOf("flclashm_always_on.json", "flclashx_always_on.json",
            "flclashm_runtime_nodes.json", "flclashx_runtime_nodes.json",
            "flclashm_vpn_active", "flclashx_vpn_active", "flclashm_notif_title",
            "flclashx_notif_title", "flclashx_start_time")) {
            File(GlobalState.application.filesDir, name).delete()
        }
    }
}
