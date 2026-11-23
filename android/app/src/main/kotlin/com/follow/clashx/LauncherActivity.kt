package com.follow.clashx

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.service.quicksettings.TileService.ACTION_QS_TILE_PREFERENCES

/** Gives the app task a stable identity while the launcher aliases can change. */
class LauncherActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android resolves the starting window before MainActivity.onCreate.
        StartupAppearance.read(this).applySplashTheme(this)
        val main = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        when (intent.action) {
            Intent.ACTION_VIEW -> main.setAction(Intent.ACTION_VIEW).setData(intent.data)
            ACTION_QS_TILE_PREFERENCES -> main.setAction(ACTION_QS_TILE_PREFERENCES)
            else -> main.setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        }
        startActivity(main)
        finish()
    }
}
