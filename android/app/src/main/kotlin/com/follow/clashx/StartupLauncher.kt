package com.follow.clashx

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import android.os.Build
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.graphics.drawable.IconCompat
import com.follow.clashx.common.diagnostics.DiagnosticLog

internal enum class LauncherEntry {
    System, SystemBlack, Light, Dark, Black;

    fun component(context: Context) = ComponentName(context, "com.follow.clashx.Launcher$name")
}

/** Changes presentation only. Each alias routes through LauncherActivity. */
internal object StartupLauncher {
    fun apply(context: Context, selected: LauncherEntry) {
        val pm = context.packageManager
        fun enabled(entry: LauncherEntry): Boolean = when (pm.getComponentEnabledSetting(entry.component(context))) {
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> entry == LauncherEntry.System
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            else -> false
        }
        fun setEnabled(entry: LauncherEntry, value: Boolean) {
            val state = if (value) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            pm.setComponentEnabledSetting(entry.component(context), state, PackageManager.DONT_KILL_APP)
        }

        try {
            val previous = LauncherEntry.entries.filter { it != selected && enabled(it) }
            if (!enabled(selected)) setEnabled(selected, true)
            // Keep a working entry and its shortcuts if publishing the new one
            // fails. The next resume or shortcut publication retries the switch.
            if (previous.isNotEmpty() && moveShortcuts(context, selected.component(context))) {
                previous.forEach { setEnabled(it, false) }
            }
        } catch (failure: RuntimeException) {
            DiagnosticLog.w("StartupLauncher", "Could not update launcher appearance: ${failure.javaClass.simpleName}")
        }
    }

    fun componentForShortcuts(context: Context): ComponentName =
        StartupAppearance.read(context).launcher.component(context)

    private fun moveShortcuts(context: Context, launcher: ComponentName): Boolean {
        if (Build.VERSION.SDK_INT < 25) return true
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return true
        val moved = manager.dynamicShortcuts.filter { it.activity != launcher }.map { shortcut ->
            val builder = ShortcutInfoCompat.Builder(context, shortcut).setActivity(launcher)
            val icon = when (shortcut.id) {
                "start" -> R.drawable.ic_shortcut_start
                "stop" -> R.drawable.ic_shortcut_stop
                "toggle" -> R.drawable.ic_shortcut_toggle
                else -> null
            }
            if (icon != null) builder.setIcon(IconCompat.createWithResource(context, icon))
            builder.build().toShortcutInfo()
        }
        return moved.isEmpty() || manager.updateShortcuts(moved)
    }
}
