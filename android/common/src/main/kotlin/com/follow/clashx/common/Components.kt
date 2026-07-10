package com.follow.clashx.common

import android.content.ComponentName

object Components {
    const val PACKAGE_NAME = "com.follow.clashx"
    private const val TILE_SERVICE_CLASS = "$PACKAGE_NAME.services.FlClashMTileService"

    val runtimePackageName: String
        get() = GlobalState.application.packageName

    val receiveBroadcastPermission: String
        get() = "$runtimePackageName.permission.RECEIVE_BROADCASTS"

    val MAIN_ACTIVITY get() = ComponentName(runtimePackageName, "$PACKAGE_NAME.MainActivity")
    val TEMP_ACTIVITY get() = ComponentName(runtimePackageName, "$PACKAGE_NAME.TempActivity")
    val BOOT_RECEIVER get() = ComponentName(runtimePackageName, "$PACKAGE_NAME.BootReceiver")
    val TILE_SERVICE get() = ComponentName(runtimePackageName, TILE_SERVICE_CLASS)
}
