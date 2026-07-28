package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.appcompat.app.AppCompatDelegate
import com.follow.clashx.plugins.AppPlugin
import com.follow.clashx.plugins.SelfUpdateContinuationController
import com.follow.clashx.plugins.SelfUpdateForegroundActivity
import com.follow.clashx.plugins.ServicePlugin
import com.follow.clashx.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private var boundEngine: FlutterEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        applyAppTheme()
        super.onCreate(savedInstanceState)
        // High refresh rate is driven from Dart via the flutter_displaymode package
        // (see main.dart) — it pins the fastest mode at the current resolution and
        // handles the OEM quirks that a hand-rolled preferredDisplayModeId missed.
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
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        boundEngine = flutterEngine
        GlobalState.flutterEngine = flutterEngine

        GlobalState.getCurrentAppPlugin()?.requestNotificationsPermission()
        maybeRequestBatteryExemption()
        GlobalState.syncStatus()
    }

    override fun onResume() {
        super.onResume()
        SelfUpdateForegroundActivity.onResumed(this)
        SelfUpdateContinuationController.resumePending(this)
    }

    override fun onPause() {
        SelfUpdateForegroundActivity.onPaused(this)
        super.onPause()
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

    private fun applyAppTheme() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val configJson = prefs.getString("flutter.config", null)
            val themeMode = configJson
                ?.let { JSONObject(it).optJSONObject("themeProps")?.optString("themeMode", "ThemeMode.system") }
                ?: "ThemeMode.system"
            when {
                themeMode.contains("light", ignoreCase = true) ->
                    AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_NO)
                themeMode.contains("dark", ignoreCase = true) ->
                    AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_YES)
                else ->
                    AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
            }
        } catch (_: Exception) {
            AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
        }
    }
}
