package com.follow.clashx

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A projection of committed Go settings for use before the backend is available. */
internal data class StartupAppearance(val mode: String, val pureBlack: Boolean) {
    fun background(configuration: Configuration): Int {
        val dark = when (mode) {
            "light" -> false
            "dark" -> true
            else -> configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        }
        return when {
            !dark -> R.color.brand_light_background
            pureBlack -> R.color.brand_black_background
            else -> R.color.brand_dark_background
        }
    }

    // In system mode the selected style has day/night resources, so Android
    // can resolve the current palette even while the app process is dead.
    val splashTheme: Int get() = when (mode) {
        "light" -> R.style.StartupLight
        "dark" -> if (pureBlack) R.style.StartupBlack else R.style.StartupDark
        else -> if (pureBlack) R.style.StartupSystemBlack else 0
    }

    fun applySplashTheme(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && appliedSplashTheme != splashTheme) {
            activity.splashScreen.setSplashScreenTheme(splashTheme)
            appliedSplashTheme = splashTheme
        }
    }

    val launcher: LauncherEntry get() = when (mode) {
        "light" -> LauncherEntry.Light
        "dark" -> if (pureBlack) LauncherEntry.Black else LauncherEntry.Dark
        else -> if (pureBlack) LauncherEntry.SystemBlack else LauncherEntry.System
    }

    companion object {
        private const val PREFERENCES = "flclashm_startup_theme"
        private const val MODE = "themeMode"
        private const val BLACK = "pureBlack"
        private var appliedSplashTheme: Int? = null
        private val projected = MutableStateFlow<StartupAppearance?>(null)
        val changes = projected.asStateFlow()

        fun read(context: Context): StartupAppearance {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            return StartupAppearance(preferences.getString(MODE, null) ?: "system", preferences.getBoolean(BLACK, false))
        }

        fun project(context: Context, mode: String, black: Boolean) {
            val next = StartupAppearance(mode, black)
            if (projected.value == next) return
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            if (!preferences.contains(MODE) || read(context) != next) {
                preferences.edit().putString(MODE, mode).putBoolean(BLACK, black).apply()
            }
            projected.value = next
            StartupLauncher.apply(context, next.launcher)
        }
    }
}
