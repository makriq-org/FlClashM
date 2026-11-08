package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import com.follow.clashx.plugins.BatteryPlugin
import com.follow.clashx.plugins.AppPlugin
import com.follow.clashx.plugins.DiagnosticsPlugin
import com.follow.clashx.plugins.ServicePlugin
import com.follow.clashx.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterActivity() {

    private val highRefreshRate by lazy { HighRefreshRate(this) }

    private var boundEngine: FlutterEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        applyAppTheme()
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawable(getDrawable(StartupTheme.drawable(this)))
        if (Build.VERSION.SDK_INT >= 31) splashScreen.setSplashScreenTheme(StartupTheme.theme(this))
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        StartupTheme.apply(this)
    }

    override fun onResume() {
        super.onResume()
        highRefreshRate.pin()
        StartupTheme.apply(this)
    }

    override fun onPause() {
        highRefreshRate.release()
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.makriq.flclash/startup_appearance")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> result.success(StartupTheme.appearance(this))
                    "write" -> {
                        val mode = call.argument<String>("themeMode")
                        if (mode !in setOf("system", "light", "dark")) {
                            result.error("invalid_appearance", "Expected theme mode", null)
                        } else {
                            StartupTheme.storeAppearance(this, mode!!, call.argument<Boolean>("pureBlack") == true)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
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

    // Theme the first frame before Flutter renders. The value is a startup-only
    // cache of the Go settings projection; legacy preferences are not read.
    private fun applyAppTheme() {
        setTheme(StartupTheme.theme(this))
    }
}

// Explicit launch targets let Android draw the correct starting window even
// before this process exists, including API 24–30.
class LightLaunchActivity : MainActivity()
class DarkLaunchActivity : MainActivity()
class BlackLaunchActivity : MainActivity()
class SystemBlackLaunchActivity : MainActivity()

/** Startup-only projection; Go remains the settings authority. */
internal object StartupTheme {
    private const val PREFERENCES = "flclashm_startup_theme"
    private const val KEY = "themeMode"

    fun storeAppearance(context: Context, mode: String, pureBlack: Boolean) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString(KEY, mode).putBoolean("pureBlack", pureBlack).apply()
        apply(context)
        if (Build.VERSION.SDK_INT >= 31 && context is android.app.Activity) {
            context.splashScreen.setSplashScreenTheme(theme(context))
        }
    }

    private fun dark(context: Context): Boolean = when (read(context)) {
        "dark" -> true
        "light" -> false
        else -> context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }

    private fun black(context: Context) = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        .getBoolean("pureBlack", false)

    fun theme(context: Context): Int = when {
        read(context) !in listOf("light", "dark") -> if (black(context)) R.style.StartupSystemBlack else R.style.LaunchTheme
        !dark(context) -> R.style.StartupLight
        black(context) -> R.style.StartupBlack
        else -> R.style.StartupDark
    }

    fun appearance(context: Context): Map<String, Any> = mapOf(
        "themeMode" to (read(context) ?: "system"), "pureBlack" to black(context),
    )

    fun drawable(context: Context): Int = when (theme(context)) {
        R.style.StartupLight -> R.drawable.startup_light
        R.style.StartupDark -> R.drawable.startup_dark
        R.style.StartupBlack -> R.drawable.startup_black
        R.style.StartupSystemBlack -> R.drawable.startup_systemblack
        else -> R.drawable.launch_background
    }

    fun apply(context: Context) {
        val selected = when {
            read(context) !in listOf("light", "dark") -> if (black(context)) "LauncherSystemBlack" else "LauncherSystem"
            !dark(context) -> "LauncherLight"
            black(context) -> "LauncherBlack"
            else -> "LauncherDark"
        }
        val pm = context.packageManager
        val names = listOf("LauncherSystem", "LauncherSystemBlack", "LauncherLight", "LauncherDark", "LauncherBlack")
        // Enable first, so there is always a reachable launcher entry.
        for (name in listOf(selected) + names.filter { it != selected }) {
            val component = android.content.ComponentName(context, "com.follow.clashx.$name")
            val state = if (name == selected) android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            try {
                if (pm.getComponentEnabledSetting(component) != state) {
                    pm.setComponentEnabledSetting(component, state, android.content.pm.PackageManager.DONT_KILL_APP)
                }
            } catch (error: RuntimeException) {
                android.util.Log.w("StartupTheme", "Launcher update failed; retry on resume", error)
                // Never disable the old entry if enabling its replacement failed.
                break
            }
        }

    }

    fun store(context: Context, mode: String) {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getString(KEY, null) != mode) preferences.edit().putString(KEY, mode).apply()
    }

    fun read(context: Context): String? = runCatching {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY, null)
    }.getOrNull()

}
