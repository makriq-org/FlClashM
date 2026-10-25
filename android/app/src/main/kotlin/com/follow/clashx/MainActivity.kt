package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.appcompat.app.AppCompatDelegate
import com.follow.clashx.plugins.BatteryPlugin
import com.follow.clashx.plugins.AppPlugin
import com.follow.clashx.plugins.DiagnosticsPlugin
import com.follow.clashx.plugins.ServicePlugin
import com.follow.clashx.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val highRefreshRate by lazy { HighRefreshRate(this) }

    private var boundEngine: FlutterEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        applyAppTheme()
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        highRefreshRate.pin()
    }

    override fun onPause() {
        highRefreshRate.release()
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.makriq.flclash/device_id")
            .setMethodCallHandler { call, result ->
                if (call.method == "getAndroidId") {
                    try {
                        val androidId = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID,
                        )
                        result.success(androidId)
                    } catch (e: Exception) {
                        result.error("ANDROID_ID_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(BatteryPlugin())
        flutterEngine.plugins.add(DiagnosticsPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        boundEngine = flutterEngine
        GlobalState.flutterEngine = flutterEngine

        GlobalState.getCurrentAppPlugin()?.requestNotificationsPermission()
        maybeRequestBatteryExemption()
        GlobalState.syncStatus()
    }

    // Prompt once (ever) to whitelist from battery optimization. No-op if already
    // exempt, and gated by a persisted flag so a user who declines is never nagged
    // again. This is the most effective survival lever on MIUI/Samsung, where the
    // OEM force-stops the :remote process and START_STICKY does not bring it back.
    private fun maybeRequestBatteryExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val pm = getSystemService(PowerManager::class.java) ?: return
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (prefs.getBoolean("flutter.battery_opt_prompted", false)) return
        prefs.edit().putBoolean("flutter.battery_opt_prompted", true).apply()
        runCatching {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
    }

    override fun onDestroy() {
        // Clear the global pointer only if it still references THIS activity's
        // engine. During recreation (theme change, OEM relaunch) the new
        // activity's configureFlutterEngine can run before this onDestroy; an
        // unconditional null would wipe the live new engine, forcing tile/widget
        // actions onto the headless path while a UI is actually on screen.
        if (GlobalState.flutterEngine === boundEngine) {
            GlobalState.flutterEngine = null
        }
        boundEngine = null
        super.onDestroy()
    }

    // Theme the first frame before Flutter renders. The value is a startup-only
    // cache of the Go settings projection; legacy preferences are not read.
    private fun applyAppTheme() {
        AppCompatDelegate.setDefaultNightMode(StartupTheme.nightMode(StartupTheme.read(this)))
    }
}

/** Startup-only cache of the Go settings theme, written in this process from
 * the StateHub projection. Go stays the source of truth. */
internal object StartupTheme {
    private const val PREFERENCES = "flclashm_startup_theme"
    private const val KEY = "themeMode"

    fun store(context: Context, mode: String) {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getString(KEY, null) != mode) preferences.edit().putString(KEY, mode).apply()
    }

    fun read(context: Context): String? = runCatching {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY, null)
    }.getOrNull()

    fun nightMode(mode: String?): Int = when (mode) {
        "light" -> AppCompatDelegate.MODE_NIGHT_NO
        "dark" -> AppCompatDelegate.MODE_NIGHT_YES
        else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
    }
}
