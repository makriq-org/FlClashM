package com.follow.clashx.common

import android.content.ComponentName

object Components {
    const val PACKAGE_NAME = "com.follow.clashx"

    val MAIN_ACTIVITY = ComponentName(PACKAGE_NAME, "$PACKAGE_NAME.MainActivity")
    val TEMP_ACTIVITY = ComponentName(PACKAGE_NAME, "$PACKAGE_NAME.TempActivity")
    val BOOT_RECEIVER = ComponentName(PACKAGE_NAME, "$PACKAGE_NAME.BootReceiver")
    val TILE_SERVICE = ComponentName(PACKAGE_NAME, "$PACKAGE_NAME.TileService")
}
