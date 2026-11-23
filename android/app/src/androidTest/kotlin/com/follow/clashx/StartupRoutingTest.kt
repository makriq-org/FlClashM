package com.follow.clashx

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService.ACTION_QS_TILE_PREFERENCES
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StartupRoutingTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test fun paletteIsIndependentOfTheLauncherComponent() {
        for (night in listOf(false, true)) {
            val configuration = Configuration(context.resources.configuration).apply {
                val mask = Configuration.UI_MODE_NIGHT_MASK
                uiMode = (uiMode and mask.inv()) or if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            for (mode in listOf("system", "light", "dark")) for (black in listOf(false, true)) {
                val appearance = StartupAppearance(mode, black)
                val dark = mode == "dark" || (mode == "system" && night)
                val expectedBackground = when {
                    !dark -> R.color.brand_light_background
                    black -> R.color.brand_black_background
                    else -> R.color.brand_dark_background
                }
                assertEquals("$mode with pure black $black and system night $night", expectedBackground,
                    appearance.background(configuration))
                val component = appearance.launcher.component(context)
                val info = context.packageManager.getActivityInfo(component, PackageManager.MATCH_DISABLED_COMPONENTS)
                assertEquals(LauncherActivity::class.java.name, info.targetActivity)
            }
        }
        assertEquals(0, StartupAppearance("system", false).splashTheme)
        assertEquals(R.style.StartupSystemBlack, StartupAppearance("system", true).splashTheme)
    }

    @Test fun supportedLinksEnterThroughThemedLauncherActivity() {
        for (scheme in listOf("clash", "flclash", "flclashx", "flclashm", "clashmeta", "clashx")) {
            val link = Intent(Intent.ACTION_VIEW, Uri.parse("$scheme://install-config?url=test"))
                .addCategory(Intent.CATEGORY_BROWSABLE).setPackage(context.packageName)
            val handlers = context.packageManager.queryIntentActivities(link, 0)
            assertEquals(scheme, LauncherActivity::class.java.name, handlers.single().activityInfo.name)
            link.data = Uri.parse("$scheme://unexpected-host")
            assertTrue(context.packageManager.queryIntentActivities(link, 0).isEmpty())
        }
    }

    @Test fun themeSwitchKeepsLauncherActivityOpen() = assertLauncherSwitchKeepsActivity(
        launcherIntent().setComponent(LauncherEntry.Light.component(context)),
    )

    @Test fun themedLauncherReusesActivityOpenedByLink() = assertLauncherSwitchKeepsActivity(
        Intent(Intent.ACTION_VIEW, Uri.parse("flclashm://install-config?url="))
            .addCategory(Intent.CATEGORY_BROWSABLE).setPackage(context.packageName),
    )

    @Test fun themedLauncherReusesActivityOpenedByTilePreferences() {
        val intent = Intent(ACTION_QS_TILE_PREFERENCES).setPackage(context.packageName)
        val launcher = LauncherActivity::class.java.name
        assertEquals(launcher, context.packageManager.resolveActivity(intent, 0)?.activityInfo?.name)
        assertLauncherSwitchKeepsActivity(intent.setComponent(ComponentName(context, launcher)))
    }

    private fun assertLauncherSwitchKeepsActivity(initialIntent: Intent) = runBlocking {
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
        suspend fun setAppearance(mode: String, entry: LauncherEntry) {
            Service.backendCommand("settings.patch", JSONObject().put("patch",
                JSONObject().put("themeProps", JSONObject().put("themeMode", mode).put("pureBlack", false))))
            withTimeout(15_000) {
                while (context.packageManager.queryIntentActivities(launcherIntent(), 0)
                        .singleOrNull()?.activityInfo?.name != entry.component(context).className) delay(50)
            }
        }
        application.registerActivityLifecycleCallbacks(callbacks)
        try {
            setAppearance("light", LauncherEntry.Light)
            context.startActivity(initialIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
            assertTrue("MainActivity did not open", resumed.get().await(30, TimeUnit.SECONDS))
            val original = activity.get()
            val engine = GlobalState.flutterEngine
            assertNotNull(engine)
            val marker = Any()
            val main = ComponentName(context, MainActivity::class.java)
            instrumentation.runOnMainSync {
                assertEquals(main, original.intent.component)
                assertEquals(initialIntent.action, original.intent.action)
                assertEquals(initialIntent.data, original.intent.data)
                original.window.decorView.tag = marker
            }
            val tasks = context.getSystemService(ActivityManager::class.java).appTasks
            val appTask = tasks.mapNotNull { it.taskInfo }.single { it.persistentId == original.taskId }
            assertEquals("The UI task must be independent of the launcher alias", main, appTask.baseIntent.component)

            // Change theme while the screen opened by the old alias is still visible.
            // The old alias must disappear without finishing that task.
            setAppearance("dark", LauncherEntry.Dark)
            instrumentation.waitForIdleSync()
            assertEquals("Theme switch destroyed the activity", 0, destroyed.get())
            assertSame(engine, GlobalState.flutterEngine)
            instrumentation.runOnMainSync {
                assertFalse("The open screen is finishing", original.isFinishing)
                assertSame(marker, original.window.decorView.tag)
                original.moveTaskToBack(true)
            }
            instrumentation.waitForIdleSync()
            resumed.set(CountDownLatch(1))
            context.startActivity(launcherIntent().setComponent(LauncherEntry.Dark.component(context))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
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
            Service.backendCommand("settings.patch", JSONObject().put("patch", JSONObject().put("themeProps", previous)))
        }
    }

    @Test fun switchingAliasKeepsDynamicShortcuts() {
        if (Build.VERSION.SDK_INT < 25) return
        val manager = context.getSystemService(ShortcutManager::class.java)
        val persisted = StartupAppearance.read(context)
        val light = LauncherEntry.Light.component(context)
        val dark = LauncherEntry.Dark.component(context)
        val open = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
        try {
            instrumentation.runOnMainSync {
                StartupLauncher.apply(context, LauncherEntry.Light)
                assertTrue(manager.addDynamicShortcuts(listOf(
                    ShortcutInfo.Builder(context, "startup-switch-test").setShortLabel("Startup test")
                        .setActivity(light).setIntent(open).build())))
                StartupLauncher.apply(context, LauncherEntry.Dark)
            }
            val moved = manager.dynamicShortcuts.single { it.id == "startup-switch-test" }
            assertEquals(dark, moved.activity)
            assertEquals(open.component, moved.intent!!.component)
            assertEquals("Startup test", moved.shortLabel.toString())
            assertEquals(dark.className, context.packageManager.queryIntentActivities(launcherIntent(), 0).single().activityInfo.name)
        } finally {
            manager.removeDynamicShortcuts(listOf("startup-switch-test"))
            instrumentation.runOnMainSync { StartupLauncher.apply(context, persisted.launcher) }
        }
    }

    private fun launcherIntent() = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        .setPackage(context.packageName)
}
