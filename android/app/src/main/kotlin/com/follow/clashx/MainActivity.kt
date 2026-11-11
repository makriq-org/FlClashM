package com.follow.clashx

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
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
        installSplashScreen()
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawable(getDrawable(StartupTheme.drawable(this)))
        // Each launch target has an explicit theme. A global override could
        // outlive a headless Go settings update and mask the new target's theme.
        if (Build.VERSION.SDK_INT >= 31) splashScreen.setSplashScreenTheme(0)
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

// No window is drawn here: choose a manifest-themed target before its starting
// window is created, including on Android versions without persisted splash themes.
class LinkLaunchActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(StartupIntents.forward(this, intent, StartupTheme.launchActivity(this)))
        finish()
    }
}

internal object StartupIntents {
    fun forward(context: Context, source: Intent, target: Class<out android.app.Activity>): Intent =
        Intent(source).setClass(context, target).apply {
            // Preserve the URL, action, extras and URI grants, but do not replay
            // caller task flags (e.g. CLEAR_TASK) when handing off to MainActivity.
            flags = (source.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)) or
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
}

// Starting windows belong to these short-lived tasks. They never own a
// FlutterEngine; all routes converge on the singleTask MainActivity.
open class StartupLaunchActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        splash.setKeepOnScreenCondition { true }
        if (Build.VERSION.SDK_INT >= 31) splashScreen.setSplashScreenTheme(0)
        startActivity(StartupIntents.forward(this, intent, MainActivity::class.java))
        finish()
    }
}
class SystemLaunchActivity : StartupLaunchActivity()
class LightLaunchActivity : StartupLaunchActivity()
class DarkLaunchActivity : StartupLaunchActivity()
class BlackLaunchActivity : StartupLaunchActivity()
class SystemBlackLaunchActivity : StartupLaunchActivity()

/** Startup-only projection; Go remains the settings authority. */
internal object StartupTheme {
    private const val PREFERENCES = "flclashm_startup_theme"
    private const val KEY = "themeMode"

    fun storeAppearance(context: Context, mode: String, pureBlack: Boolean) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString(KEY, mode).putBoolean("pureBlack", pureBlack).apply()
        apply(context)
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

    fun launchActivity(context: Context): Class<out StartupLaunchActivity> = when (theme(context)) {
        R.style.StartupLight -> LightLaunchActivity::class.java
        R.style.StartupDark -> DarkLaunchActivity::class.java
        R.style.StartupBlack -> BlackLaunchActivity::class.java
        R.style.StartupSystemBlack -> SystemBlackLaunchActivity::class.java
        else -> SystemLaunchActivity::class.java
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

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var retry: Runnable? = null

    private fun schedule(context: Context) {
        if (retry != null) return
        val application = context.applicationContext
        val task = Runnable {
            retry = null
            apply(application)
        }
        retry = task
        handler.postDelayed(task, 2000L)
    }

    fun apply(context: Context) {
        val application = context.applicationContext
        if (android.os.Looper.myLooper() != handler.looper) {
            handler.post { apply(application) }
            return
        }
        retry?.let { handler.removeCallbacks(it) }
        retry = null
        val selected = when {
            read(application) !in listOf("light", "dark") -> if (black(application)) "LauncherSystemBlack" else "LauncherSystem"
            !dark(application) -> "LauncherLight"
            black(application) -> "LauncherBlack"
            else -> "LauncherDark"
        }
        val pm = application.packageManager
        val names = listOf("LauncherSystem", "LauncherSystemBlack", "LauncherLight", "LauncherDark", "LauncherBlack")
        // A failed task query is not evidence that an alias is unused.
        val activeTasks = runCatching {
            application.getSystemService(android.app.ActivityManager::class.java).appTasks
                .mapNotNull { checkNotNull(it.taskInfo).baseIntent.component?.className }.toSet()
        }.getOrNull()
        val activeAliases = activeTasks?.map { it.substringAfterLast('.') }?.toSet()
        val pending = LauncherSwitch.apply(selected, names, activeAliases) { name, enabled ->
            val component = android.content.ComponentName(application, "com.follow.clashx.$name")
            val state = if (enabled) android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            if (pm.getComponentEnabledSetting(component) != state) {
                pm.setComponentEnabledSetting(component, state, android.content.pm.PackageManager.DONT_KILL_APP)
            }
        }
        if (pending) schedule(application)
    }

    fun read(context: Context): String? = runCatching {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY, null)
    }.getOrNull()

}
