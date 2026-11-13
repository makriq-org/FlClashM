package com.follow.clashx

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Exercise real Android Intent copies and installed manifest theme selection. */
@RunWith(AndroidJUnit4::class)
class StartupRoutingTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun themedLauncherReusesActivityOpenedByLink() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val application = context.applicationContext as Application
        val activity = AtomicReference<MainActivity>()
        val created = AtomicInteger()
        val destroyed = AtomicInteger()
        val resumed = AtomicReference(CountDownLatch(1))
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(value: Activity, state: Bundle?) {
                if (value is MainActivity) {
                    activity.set(value)
                    created.incrementAndGet()
                }
            }
            override fun onActivityResumed(value: Activity) {
                if (value is MainActivity) resumed.get().countDown()
            }
            override fun onActivityDestroyed(value: Activity) {
                if (value is MainActivity) destroyed.incrementAndGet()
            }
            override fun onActivityStarted(value: Activity) {}
            override fun onActivityPaused(value: Activity) {}
            override fun onActivityStopped(value: Activity) {}
            override fun onActivitySaveInstanceState(value: Activity, state: Bundle) {}
        }
        Service.bind()
        val settings = Service.backend("snapshot").getJSONObject("catalog").getJSONObject("settings")
        val previous = settings.optJSONObject("themeProps") ?: JSONObject()
        suspend fun appearance(mode: String) {
            Service.backendCommand("settings.patch", JSONObject().put("patch",
                JSONObject().put("themeProps", JSONObject().put("themeMode", mode).put("pureBlack", false))))
            instrumentation.runOnMainSync { StartupTheme.storeAppearance(context, mode, false) }
        }
        application.registerActivityLifecycleCallbacks(callbacks)
        try {
            appearance("light")
            // Empty import URL exercises routing without fetching a subscription.
            val uri = Uri.parse("flclashm://install-config?url=")
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(context.packageName)
                .putExtra("source", "startup-routing-test").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            assertTrue("Link did not open MainActivity", resumed.get().await(30, TimeUnit.SECONDS))
            withTimeout(30_000L) { while (GlobalState.flutterEngine == null) delay(100) }
            val original = activity.get()
            val engine = GlobalState.flutterEngine
            val marker = Any()
            instrumentation.runOnMainSync {
                assertEquals(uri, original.intent.data)
                assertEquals("startup-routing-test", original.intent.getStringExtra("source"))
                original.window.decorView.tag = marker
            }
            appearance("dark")
            instrumentation.runOnMainSync { original.moveTaskToBack(true) }
            instrumentation.waitForIdleSync()
            resumed.set(CountDownLatch(1))
            // Resolve the enabled launcher through PackageManager, without
            // RESET_TASK_IF_NEEDED or a direct call to MainActivity.
            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .setPackage(context.packageName)
            val handlers = context.packageManager.queryIntentActivities(launcher, 0)
            val dark = handlers.single { it.activityInfo.name.endsWith(".LauncherDark") }
            context.startActivity(launcher.setComponent(ComponentName(context.packageName, dark.activityInfo.name))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            assertTrue("Launcher did not resume MainActivity", resumed.get().await(30, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            assertEquals("A second FlutterActivity was created", 1, created.get())
            assertEquals("Theme switch destroyed the activity", 0, destroyed.get())
            assertSame(original, activity.get())
            assertSame(engine, GlobalState.flutterEngine)
            instrumentation.runOnMainSync { assertSame(marker, original.window.decorView.tag) }
        } finally {
            application.unregisterActivityLifecycleCallbacks(callbacks)
            instrumentation.runOnMainSync { activity.get()?.finish() }
            Service.backendCommand("settings.patch", JSONObject().put("patch",
                JSONObject().put("themeProps", previous)))
            instrumentation.runOnMainSync {
                StartupTheme.storeAppearance(context, previous.optString("themeMode", "system"),
                    previous.optBoolean("pureBlack", false))
            }
        }
    }

    @Test fun themeSwitchPreservesDynamicShortcuts() {
        if (android.os.Build.VERSION.SDK_INT < 25) return
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val manager = context.getSystemService(android.content.pm.ShortcutManager::class.java)
        val previous = StartupTheme.appearance(context)
        val saved = manager.dynamicShortcuts
        try {
            instrumentation.runOnMainSync { StartupTheme.storeAppearance(context, "light", false) }
            val light = ComponentName(context.packageName, "com.follow.clashx.LauncherLight")
            val dark = ComponentName(context.packageName, "com.follow.clashx.LauncherDark")
            val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
            assertTrue(manager.setDynamicShortcuts(listOf(
                android.content.pm.ShortcutInfo.Builder(context, "startup-switch-test")
                    .setShortLabel("Startup test").setActivity(light).setIntent(intent).build())))
            instrumentation.runOnMainSync { StartupTheme.storeAppearance(context, "dark", false) }
            val moved = manager.dynamicShortcuts.single { it.id == "startup-switch-test" }
            assertEquals(dark, moved.activity)
            assertEquals(intent.component, moved.intent!!.component)
            assertEquals("Startup test", moved.shortLabel.toString())
        } finally {
            manager.removeDynamicShortcuts(listOf("startup-switch-test"))
            instrumentation.runOnMainSync {
                StartupTheme.storeAppearance(context, previous["themeMode"] as String, previous["pureBlack"] as Boolean)
            }
            manager.setDynamicShortcuts(saved)
        }
    }

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
