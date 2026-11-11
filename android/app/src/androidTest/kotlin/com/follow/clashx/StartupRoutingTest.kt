package com.follow.clashx

import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Exercise real Android Intent copies and installed manifest theme selection. */
@RunWith(AndroidJUnit4::class)
class StartupRoutingTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun externalLinksResolveToOneInvisibleRouter() {
        for (scheme in listOf("clash", "flclash", "flclashx", "flclashm", "clashmeta", "clashx")) {
            val link = Intent(Intent.ACTION_VIEW, Uri.parse("$scheme://install-config?url=test"))
                .addCategory(Intent.CATEGORY_BROWSABLE).setPackage(context.packageName)
            val handlers = context.packageManager.queryIntentActivities(link, 0)
            assertEquals(scheme, 1, handlers.size)
            val info = handlers.single().activityInfo
            assertEquals(LinkLaunchActivity::class.java.name, info.name)
            val theme = android.view.ContextThemeWrapper(context, info.themeResource)
            val flags = theme.obtainStyledAttributes(intArrayOf(
                android.R.attr.windowNoDisplay, android.R.attr.windowDisablePreview))
            try {
                assertTrue(flags.getBoolean(0, false))
                assertTrue(flags.getBoolean(1, false))
            } finally { flags.recycle() }
            link.data = Uri.parse("$scheme://unexpected-host")
            assertTrue(context.packageManager.queryIntentActivities(link, 0).isEmpty())
        }
    }

    @Test fun linksKeepTheirPayloadThroughBothLaunchHops() {
        val original = Intent(Intent.ACTION_VIEW,
            Uri.parse("flclashm://install-config?url=https%3A%2F%2Fexample.com%2Fprofile%3Ftoken%3Da%252Bb"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .putExtra("source", "link-test")
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val launch = StartupIntents.forward(context, original, BlackLaunchActivity::class.java)
        val main = StartupIntents.forward(context, launch, MainActivity::class.java)
        assertEquals(ComponentName(context, BlackLaunchActivity::class.java), launch.component)
        assertEquals(ComponentName(context, MainActivity::class.java), main.component)
        for (forwarded in listOf(launch, main)) {
            assertEquals(original.data, forwarded.data)
            assertEquals(Intent.ACTION_VIEW, forwarded.action)
            assertEquals(original.categories, forwarded.categories)
            assertEquals("link-test", forwarded.getStringExtra("source"))
            assertEquals(0, forwarded.flags and Intent.FLAG_ACTIVITY_CLEAR_TASK)
            assertNotEquals(0, forwarded.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            assertNotEquals(0, forwarded.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        assertNull(original.component)
        assertNotEquals(0, original.flags and Intent.FLAG_ACTIVITY_CLEAR_TASK)
    }

    @Test fun cachedAppearanceSelectsManifestThemeBeforeOpeningTheWindow() {
        // A separate preference file avoids changing the user's cache or aliases.
        val name = "startup-routing-test"
        try {
            for (night in listOf(false, true)) {
                val configuration = Configuration(context.resources.configuration).apply {
                    uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                        if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                }
                val themed = object : ContextWrapper(context.createConfigurationContext(configuration)) {
                    override fun getSharedPreferences(ignored: String, mode: Int): SharedPreferences =
                        context.getSharedPreferences(name, mode)
                }
                for (mode in listOf("system", "light", "dark")) for (black in listOf(false, true)) {
                    themed.getSharedPreferences(name, Context.MODE_PRIVATE).edit()
                        .putString("themeMode", mode).putBoolean("pureBlack", black).commit()
                    val target = StartupTheme.launchActivity(themed)
                    val info = context.packageManager.getActivityInfo(ComponentName(context, target), 0)
                    val expected = when {
                        mode == "system" -> if (black) R.style.StartupSystemBlack else R.style.LaunchTheme
                        mode == "light" -> R.style.StartupLight
                        black -> R.style.StartupBlack
                        else -> R.style.StartupDark
                    }
                    assertEquals("$mode, pureBlack=$black, systemNight=$night", expected, info.themeResource)
                }
            }
        } finally {
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}
