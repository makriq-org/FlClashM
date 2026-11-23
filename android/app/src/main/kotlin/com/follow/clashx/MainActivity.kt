package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.LayerDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import androidx.lifecycle.lifecycleScope
import com.follow.clashx.plugins.BatteryPlugin
import com.follow.clashx.plugins.AppPlugin
import com.follow.clashx.plugins.DiagnosticsPlugin
import com.follow.clashx.plugins.ServicePlugin
import com.follow.clashx.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {

    private val highRefreshRate by lazy { HighRefreshRate(this) }

    private var boundEngine: FlutterEngine? = null
    private var flutterUiDisplayed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        val appearance = StartupAppearance.read(this)
        super.onCreate(savedInstanceState)
        applyStartupAppearance(appearance)
        lifecycleScope.launch {
            StartupAppearance.changes.collect { projected ->
                if (projected != null) applyStartupAppearance(projected)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        highRefreshRate.pin()
        val appearance = StartupAppearance.read(this)
        applyStartupAppearance(appearance)
        StartupLauncher.apply(this, appearance.launcher)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applyStartupAppearance(StartupAppearance.read(this))
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        flutterUiDisplayed = true
        updateWindowBackground(StartupAppearance.read(this))
    }

    override fun onPause() {
        highRefreshRate.release()
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.makriq.flclash/startup_appearance")
            .setMethodCallHandler { call, result ->
                if (call.method == "read") {
                    val appearance = StartupAppearance.read(this)
                    result.success(mapOf("themeMode" to appearance.mode, "pureBlack" to appearance.pureBlack))
                } else {
                    result.notImplemented()
                }
            }

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

    private fun applyStartupAppearance(appearance: StartupAppearance) {
        updateWindowBackground(appearance)
        appearance.applySplashTheme(this)
    }

    private fun updateWindowBackground(appearance: StartupAppearance) {
        val background = appearance.background(resources.configuration)
        val color = ColorDrawable(getColor(background))
        if (flutterUiDisplayed || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            window.setBackgroundDrawable(color)
            return
        }
        val mark = if (background == R.color.brand_light_background) R.drawable.brand_light else R.drawable.brand_dark
        val size = (168 * resources.displayMetrics.density).roundToInt()
        val launch = LayerDrawable(arrayOf(color, requireNotNull(getDrawable(mark)))).apply {
            setLayerSize(1, size, size)
            setLayerGravity(1, Gravity.CENTER)
        }
        window.setBackgroundDrawable(launch)
    }
}
