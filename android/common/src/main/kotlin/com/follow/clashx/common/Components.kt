package com.follow.clashx.common

import android.content.ComponentName

object Components {
    const val PACKAGE_NAME = "com.follow.clashx"
    // Keep the legacy tile service class name so already pinned Quick Settings
    // tiles continue to resolve after product updates.
    private const val TILE_SERVICE_CLASS = "$PACKAGE_NAME.services.FlClashXTileService"

    val runtimePackageName: String
        get() = GlobalState.application.packageName

    val receiveBroadcastPermission: String
        get() = "$runtimePackageName.permission.RECEIVE_BROADCASTS"

    val MAIN_ACTIVITY get() = ComponentName(runtimePackageName, "$PACKAGE_NAME.MainActivity")
    val TEMP_ACTIVITY get() = ComponentName(runtimePackageName, "$PACKAGE_NAME.TempActivity")
    val BOOT_RECEIVER get() = ComponentName(runtimePackageName, "$PACKAGE_NAME.BootReceiver")
    val TILE_SERVICE get() = ComponentName(runtimePackageName, TILE_SERVICE_CLASS)
}
