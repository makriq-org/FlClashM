package com.follow.clashx.plugins

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ComponentInfo
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.ContextCompat.getSystemService
import androidx.core.content.FileProvider
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile
import com.follow.clashx.FlClashApplication
import com.follow.clashx.R
import com.follow.clashx.extensions.getActionIntent
import com.follow.clashx.extensions.getBase64
import com.follow.clashx.models.Package
import com.google.gson.Gson
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.lang.ref.WeakReference
import java.util.Collections
import java.util.zip.ZipFile

// How long the installed-packages snapshot stays fresh. TTL, not load-once: a
// process-lifetime cache never showed apps (un)installed while FlClashX ran.
private const val PACKAGES_CACHE_TTL_MS = 30_000L

// Vendor runtime permission (ITGSA standard) gating the installed-app list on
// vivo/OPPO/Xiaomi ROMs; unknown on AOSP. See withInstalledAppsPermission.
private const val GET_INSTALLED_APPS_PERMISSION = "com.android.permission.GET_INSTALLED_APPS"

class AppPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private var activityRef: WeakReference<Activity>? = null

    private lateinit var channel: MethodChannel

    private lateinit var scope: CoroutineScope

    // All requesters waiting on a single in-flight VPN consent dialog. Only the
    // first launches the dialog; the result resolves every queued callback, so a
    // concurrent start (double-tap, or two start paths) can't strand a pending one.
    // Accessed only on the main thread (channel handlers + onActivityResult).
    private val vpnCallBacks = mutableListOf<(granted: Boolean) -> Unit>()

    private val iconMap: MutableMap<String, String?> = Collections.synchronizedMap(
        object : LinkedHashMap<String, String?>(128, 0.75f, true) {
            override fun removeEldestEntry(eldest: Map.Entry<String, String?>?): Boolean = size > 200
        }
    )

    private val packages = mutableListOf<Package>()
    private var packagesLoadedAt = 0L
    private var installedPackageNames: List<String> = emptyList()
    private var installedPackageNamesLoadedAt = 0L

    private val skipPrefixList = listOf(
        "com.google",
        "com.android.chrome",
        "com.android.vending",
        "com.microsoft",
        "com.apple",
        "com.zhiliaoapp.musically", // Banned by China
    )

    private val chinaAppPrefixList = listOf(
        "com.tencent",
        "com.alibaba",
        "com.umeng",
        "com.qihoo",
        "com.ali",
        "com.alipay",
        "com.amap",
        "com.sina",
        "com.weibo",
        "com.vivo",
        "com.xiaomi",
        "com.huawei",
        "com.taobao",
        "com.secneo",
        "s.h.e.l.l",
        "com.stub",
        "com.kiwisec",
        "com.secshell",
        "com.wrapper",
        "cn.securitystack",
        "com.mogosec",
        "com.secoen",
        "com.netease",
        "com.mx",
        "com.qq.e",
        "com.baidu",
        "com.bytedance",
        "com.bugly",
        "com.miui",
        "com.oppo",
        "com.coloros",
        "com.iqoo",
        "com.meizu",
        "com.gionee",
        "cn.nubia",
        "com.oplus",
        "andes.oplus",
        "com.unionpay",
        "cn.wps"
    )

    private val chinaAppRegex by lazy {
        ("(" + chinaAppPrefixList.joinToString("|").replace(".", "\\.") + ").*").toRegex()
    }

    val VPN_PERMISSION_REQUEST_CODE = 1001

    val NOTIFICATION_PERMISSION_REQUEST_CODE = 1002

    val GET_INSTALLED_APPS_PERMISSION_REQUEST_CODE = 1003

    private var isBlockNotification: Boolean = false

    // Callers waiting on a single in-flight GET_INSTALLED_APPS dialog; same
    // main-thread-only queue pattern as vpnCallBacks.
    private val installedAppsCallbacks = mutableListOf<() -> Unit>()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "app")
        channel.setMethodCallHandler(this)
    }

    private fun initShortcuts(toggle: String, start: String, stop: String) {
        val ctx = FlClashApplication.getAppContext()
        val icon = IconCompat.createWithResource(ctx, R.mipmap.ic_launcher_round)
        val toggleShortcut = ShortcutInfoCompat.Builder(ctx, "toggle")
            .setShortLabel(toggle)
            .setIcon(icon)
            .setIntent(ctx.getActionIntent("CHANGE"))
            .build()
        val startShortcut = ShortcutInfoCompat.Builder(ctx, "start")
            .setShortLabel(start)
            .setIcon(icon)
            .setIntent(ctx.getActionIntent("START"))
            .build()
        val stopShortcut = ShortcutInfoCompat.Builder(ctx, "stop")
            .setShortLabel(stop)
            .setIcon(icon)
            .setIntent(ctx.getActionIntent("STOP"))
            .build()
        ShortcutManagerCompat.setDynamicShortcuts(ctx, listOf(toggleShortcut, startShortcut, stopShortcut))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    private fun tip(message: String?) {
        // Always surface the tip. The previous `flutterEngine == null` guard silently
        // dropped every tip() coming from a Dart-invoked tile/widget flow.
        Toast.makeText(FlClashApplication.getAppContext(), message, Toast.LENGTH_LONG).show()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "moveTaskToBack" -> {
                activityRef?.get()?.moveTaskToBack(true)
                result.success(true)
            }

            "updateExcludeFromRecents" -> {
                val value = call.argument<Boolean>("value")
                updateExcludeFromRecents(value)
                result.success(true)
            }

            "initShortcuts" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, String>()
                initShortcuts(
                    toggle = args["toggle"] as? String ?: "Toggle",
                    start = args["start"] as? String ?: "Start",
                    stop = args["stop"] as? String ?: "Stop",
                )
                result.success(true)
            }

            "getPackages" -> {
                withInstalledAppsPermission {
                    scope.launch(Dispatchers.IO) {
                        val json = getPackagesToJson()
                        result.successOnMain(json)
                    }
                }
            }

            "getInstalledPackageNames" -> {
                scope.launch(Dispatchers.IO) {
                    val names = getInstalledPackageNames()
                    result.successOnMain(names)
                }
            }

            "getChinaPackageNames" -> {
                scope.launch(Dispatchers.IO) {
                    val names = getChinaPackageNames()
                    result.successOnMain(names)
                }
            }

            "getPackageIcon" -> {
                scope.launch {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.successOnMain(null)
                        return@launch
                    }
                    val packageIcon = getPackageIcon(packageName)
                    packageIcon.let {
                        if (it != null) {
                            result.successOnMain(it)
                            return@launch
                        }
                        if (iconMap["default"] == null) {
                            iconMap["default"] =
                                FlClashApplication.getAppContext().packageManager?.defaultActivityIcon?.getBase64()
                        }
                        result.successOnMain(iconMap["default"])
                        return@launch
                    }
                }
            }

            "tip" -> {
                val message = call.argument<String>("message")
                tip(message)
                result.success(true)
            }

            "openFile" -> {
                val path = call.argument<String>("path") ?: run { result.success(false); return }
                result.success(openFile(path))
            }

            "isIgnoringBatteryOptimizations" -> {
                result.success(isIgnoringBatteryOptimizations())
            }

            "requestIgnoreBatteryOptimizations" -> {
                result.success(requestIgnoreBatteryOptimizations())
            }

            "openAutoStartSettings" -> {
                result.success(openAutoStartSettings())
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val ctx = FlClashApplication.getAppContext()
        val pm = ctx.getSystemService(android.content.Context.POWER_SERVICE)
            as? android.os.PowerManager ?: return false
        return pm.isIgnoringBatteryOptimizations(ctx.packageName)
    }

    // Battery-optimization exemption is the single most effective survival lever on
    // MIUI/OneUI (the OEM force-stops the :remote process and START_STICKY doesn't
    // bring it back). Re-promptable from the UI so a one-time decline isn't permanent.
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val ctx = FlClashApplication.getAppContext()
        if (isIgnoringBatteryOptimizations()) return true
        val activity = activityRef?.get()
        return runCatching {
            @Suppress("BatteryLife")
            val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(android.net.Uri.parse("package:${ctx.packageName}"))
            if (activity != null) {
                activity.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(intent)
            }
            true
        }.getOrElse {
            // Some OEMs reject the direct request intent; fall back to the list.
            runCatching {
                val intent = Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                (activity ?: ctx).startActivity(intent)
                true
            }.getOrDefault(false)
        }
    }

    // Opens the OEM "autostart"/"background start" allowlist. Without it BootReceiver
    // and sticky restarts are blocked at the OEM level on MIUI/EMUI/ColorOS/Funtouch.
    // Tries known per-OEM activities, falling back to the app's detail settings.
    private fun openAutoStartSettings(): Boolean {
        val ctx = FlClashApplication.getAppContext()
        val activity = activityRef?.get()
        val candidates = listOf(
            // Xiaomi MIUI
            android.content.ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            // Huawei EMUI
            android.content.ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            android.content.ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            // Oppo ColorOS
            android.content.ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            android.content.ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            android.content.ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            // Vivo Funtouch
            android.content.ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            android.content.ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            // Letv
            android.content.ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"),
        )
        for (cn in candidates) {
            val intent = Intent().setComponent(cn).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (ctx.packageManager.resolveActivity(intent, 0) != null) {
                val ok = runCatching { (activity ?: ctx).startActivity(intent) }.isSuccess
                if (ok) return true
            }
        }
        // Fallback: the app's detail settings page (always present).
        return runCatching {
            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(android.net.Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            (activity ?: ctx).startActivity(intent)
            true
        }.getOrDefault(false)
    }

    private fun openFile(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            tip("File not found: ${file.name}")
            return false
        }

        val appContext = FlClashApplication.getAppContext()
        val uri = try {
            FileProvider.getUriForFile(
                appContext,
                "${appContext.packageName}.fileProvider",
                file
            )
        } catch (e: Exception) {
            android.util.Log.w("AppPlugin", "openFile uri handoff failed", e)
            return false
        }

        val mimeType = getMimeType(file)
        val intent = if (mimeType == APK_MIME_TYPE) {
            Intent(Intent.ACTION_INSTALL_PACKAGE)
        } else {
            Intent(Intent.ACTION_VIEW)
        }.apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            clipData = ClipData.newRawUri(file.name, uri)
        }

        val launchIntent = if (mimeType == APK_MIME_TYPE) {
            intent
        } else {
            Intent.createChooser(intent, file.name).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri(file.name, uri)
            }
        }

        try {
            val launcher = activityRef?.get() ?: appContext
            launcher.startActivity(launchIntent)
            return true
        } catch (_: ActivityNotFoundException) {
            tip("No app found to open ${file.name}")
            return false
        } catch (e: Exception) {
            android.util.Log.w("AppPlugin", "openFile failed", e)
            return false
        }
    }

    private fun getMimeType(file: File): String {
        val extension = file.extension.lowercase()
        if (extension == "apk") {
            return APK_MIME_TYPE
        }
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
    }

    private fun updateExcludeFromRecents(value: Boolean?) {
        val am = getSystemService(FlClashApplication.getAppContext(), ActivityManager::class.java)
        val task = am?.appTasks?.firstOrNull {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                it.taskInfo.taskId == activityRef?.get()?.taskId
            } else {
                it.taskInfo.id == activityRef?.get()?.taskId
            }
        }

        when (value) {
            true -> task?.setExcludeFromRecents(value)
            false -> task?.setExcludeFromRecents(value)
            null -> task?.setExcludeFromRecents(false)
        }
    }

    private suspend fun getPackageIcon(packageName: String): String? {
        val packageManager = FlClashApplication.getAppContext().packageManager
        // containsKey, not == null: a failed/icon-less lookup caches null so we don't
        // re-hit PackageManager on every subsequent request for the same package.
        if (!iconMap.containsKey(packageName)) {
            iconMap[packageName] = try {
                packageManager?.getApplicationIcon(packageName)?.getBase64()
            } catch (_: Exception) {
                null
            }

        }
        return iconMap[packageName]
    }

    // vivo/OPPO/Xiaomi (ITGSA) ROMs gate the installed-app list behind a vendor
    // runtime permission; without it getInstalledPackages silently returns a
    // near-empty list even with QUERY_ALL_PACKAGES held (AccessControl looks
    // blank). Prompt for it when the list is actually requested; on ROMs that
    // don't define the permission (plain AOSP/Pixel) proceed immediately.
    // Main thread only (channel handler + permission result), like vpnCallBacks.
    private fun withInstalledAppsPermission(onReady: () -> Unit) {
        val context = FlClashApplication.getAppContext()
        val activity = activityRef?.get()
        val defined = try {
            context.packageManager?.getPermissionInfo(GET_INSTALLED_APPS_PERMISSION, 0) != null
        } catch (_: Exception) {
            false
        }
        if (!defined || activity == null ||
            ContextCompat.checkSelfPermission(context, GET_INSTALLED_APPS_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            onReady()
            return
        }
        val alreadyInFlight = installedAppsCallbacks.isNotEmpty()
        installedAppsCallbacks.add(onReady)
        // Only the first requester launches the dialog; the rest ride along and
        // resolve together in onRequestPermissionsResultListener. A permanently
        // denied permission yields an immediate DENIED result — the load then
        // proceeds with whatever the ROM exposes, so callers never hang.
        if (!alreadyInFlight) {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(GET_INSTALLED_APPS_PERMISSION),
                GET_INSTALLED_APPS_PERMISSION_REQUEST_CODE
            )
        }
    }

    @Synchronized
    private fun getPackages(): List<Package> {
        val packageManager = FlClashApplication.getAppContext().packageManager
        val now = android.os.SystemClock.elapsedRealtime()
        if (packages.isNotEmpty() && now - packagesLoadedAt < PACKAGES_CACHE_TTL_MS) {
            return packages.toList()
        }
        packages.clear()
        packageManager?.getInstalledPackages(PackageManager.GET_META_DATA or PackageManager.GET_PERMISSIONS)
            ?.filter {
                it.packageName != FlClashApplication.getAppContext().packageName || it.packageName == "android"

            }?.map {
                Package(
                    packageName = it.packageName,
                    label = it.applicationInfo?.loadLabel(packageManager)?.toString() ?: it.packageName,
                    system = ((it.applicationInfo?.flags ?: 0) and ApplicationInfo.FLAG_SYSTEM) != 0,
                    lastUpdateTime = it.lastUpdateTime,
                    internet = it.requestedPermissions?.contains(Manifest.permission.INTERNET) == true
                )
            }?.let { packages.addAll(it) }
        packagesLoadedAt = now
        // Snapshot: callers serialize/filter outside this lock while a later refresh
        // may clear() the backing list mid-iteration.
        return packages.toList()
    }

    private suspend fun getPackagesToJson(): String {
        return withContext(Dispatchers.IO) {
            Gson().toJson(getPackages())
        }
    }

    @Synchronized
    private fun getInstalledPackageNamesSnapshot(): List<String> {
        val now = android.os.SystemClock.elapsedRealtime()
        if (installedPackageNamesLoadedAt != 0L &&
            now - installedPackageNamesLoadedAt < PACKAGES_CACHE_TTL_MS
        ) {
            return installedPackageNames
        }
        val packageManager = FlClashApplication.getAppContext().packageManager
        installedPackageNames = packageManager
            ?.getInstalledPackages(0)
            ?.map { it.packageName }
            ?.filter { it.isNotBlank() }
            ?.distinct()
            ?: emptyList()
        installedPackageNamesLoadedAt = now
        return installedPackageNames
    }

    private suspend fun getInstalledPackageNames(): List<String> {
        return withContext(Dispatchers.IO) {
            getInstalledPackageNamesSnapshot()
        }
    }

    private suspend fun getChinaPackageNames(): String {
        return withContext(Dispatchers.IO) {
            val packages: List<String> =
                getPackages().map { it.packageName }.filter { isChinaPackage(it) }
            Gson().toJson(packages)
        }
    }

    fun requestVpnPermission(callBack: (granted: Boolean) -> Unit) {
        val intent = VpnService.prepare(FlClashApplication.getAppContext())
        if (intent != null) {
            val activity = activityRef?.get()
            if (activity != null) {
                val alreadyInFlight = vpnCallBacks.isNotEmpty()
                vpnCallBacks.add(callBack)
                // Only the first requester launches the consent dialog; the rest
                // ride along and are resolved together in onActivityResult.
                if (!alreadyInFlight) {
                    activity.startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
                }
                return
            }
            // Consent is genuinely required but there's no activity to host the system
            // dialog (headless engine). Reporting granted here would let the start
            // proceed without permission and silently degrade to rt=0/STOP. Instead
            // route through the headless consent path (TempActivity "START" runs
            // prepare + start) and tell the in-place caller it could not start now.
            runCatching {
                val ctx = FlClashApplication.getAppContext()
                ctx.startActivity(ctx.getActionIntent("START"))
            }
            callBack(false)
            return
        }
        // Already granted: proceed.
        callBack(true)
    }

    fun requestNotificationsPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val permission = ContextCompat.checkSelfPermission(
                FlClashApplication.getAppContext(),
                Manifest.permission.POST_NOTIFICATIONS
            )
            if (permission != PackageManager.PERMISSION_GRANTED) {
                if (isBlockNotification) return
                if (activityRef?.get() == null) return
                activityRef?.get()?.let {
                    ActivityCompat.requestPermissions(
                        it,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        NOTIFICATION_PERMISSION_REQUEST_CODE
                    )
                    return
                }
            }
        }
    }

    private fun isChinaPackage(packageName: String): Boolean {
        val packageManager = FlClashApplication.getAppContext().packageManager ?: return false
        skipPrefixList.forEach {
            if (packageName == it || packageName.startsWith("$it.")) return false
        }
        val packageManagerFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            PackageManager.MATCH_UNINSTALLED_PACKAGES or PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_UNINSTALLED_PACKAGES or PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS
        }
        if (packageName.matches(chinaAppRegex)) {
            return true
        }
        try {
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(packageManagerFlags.toLong())
                )
            } else {
                packageManager.getPackageInfo(
                    packageName, packageManagerFlags
                )
            }
            mutableListOf<ComponentInfo>().apply {
                packageInfo.services?.let { addAll(it) }
                packageInfo.activities?.let { addAll(it) }
                packageInfo.receivers?.let { addAll(it) }
                packageInfo.providers?.let { addAll(it) }
            }.forEach {
                if (it.name.matches(chinaAppRegex)) return true
            }
            packageInfo.applicationInfo?.publicSourceDir?.let {
                ZipFile(File(it)).use {
                    for (packageEntry in it.entries()) {
                        if (packageEntry.name.startsWith("firebase-")) return false
                    }
                    for (packageEntry in it.entries()) {
                        if (!(packageEntry.name.startsWith("classes") && packageEntry.name.endsWith(
                                ".dex"
                            ))
                        ) {
                            continue
                        }
                        if (packageEntry.size > 15000000) {
                            return true
                        }
                        val input = it.getInputStream(packageEntry).buffered()
                        val dexFile = try {
                            DexBackedDexFile.fromInputStream(null, input)
                        } catch (e: Exception) {
                            return false
                        } finally {
                            input.close()
                        }
                        for (clazz in dexFile.classes) {
                            val clazzName =
                                clazz.type.substring(1, clazz.type.length - 1).replace("/", ".")
                                    .replace("$", ".")
                            if (clazzName.matches(chinaAppRegex)) return true
                        }
                    }
                }
            }
        } catch (_: Exception) {
            return false
        }
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityRef = WeakReference(binding.activity)
        binding.addActivityResultListener(::onActivityResult)
        binding.addRequestPermissionsResultListener(::onRequestPermissionsResultListener)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityRef = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityRef = WeakReference(binding.activity)
        // Re-register result listeners: a non-handled config change recreates the
        // ActivityPluginBinding and drops the old listeners, so an in-flight VPN
        // consent result would otherwise never arrive — permanently stranding the
        // queued vpnCallBacks (the consent dialog would never relaunch).
        binding.addActivityResultListener(::onActivityResult)
        binding.addRequestPermissionsResultListener(::onRequestPermissionsResultListener)
    }

    override fun onDetachedFromActivity() {
        channel.invokeMethod("exit", null)
        activityRef = null
        // Resolve and clear any pending consent callbacks so waiting Dart start
        // calls don't hang and the launch gate is re-armed for the next request
        // (restores the old single-callback self-healing behaviour).
        val pending = vpnCallBacks.toList()
        vpnCallBacks.clear()
        pending.forEach { it.invoke(false) }
        // Same for a permission dialog interrupted by activity teardown: resolve
        // waiters so the package-list fetch proceeds (with whatever is visible)
        // instead of stranding the Dart call.
        val pendingApps = installedAppsCallbacks.toList()
        installedAppsCallbacks.clear()
        pendingApps.forEach { it.invoke() }
    }

    private fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            val granted = resultCode == FlutterActivity.RESULT_OK
            val pending = vpnCallBacks.toList()
            vpnCallBacks.clear()
            pending.forEach { it.invoke(granted) }
        }
        return true
    }

    private fun onRequestPermissionsResultListener(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            isBlockNotification = true
        }
        if (requestCode == GET_INSTALLED_APPS_PERMISSION_REQUEST_CODE) {
            if (grantResults.any { it == PackageManager.PERMISSION_GRANTED }) {
                // A pre-grant load may have cached the ROM's stripped-down list
                // moments ago; drop it so the pending callbacks fetch the real one.
                synchronized(this) {
                    packages.clear()
                    packagesLoadedAt = 0L
                    installedPackageNames = emptyList()
                    installedPackageNamesLoadedAt = 0L
                }
            }
            val pending = installedAppsCallbacks.toList()
            installedAppsCallbacks.clear()
            pending.forEach { it.invoke() }
        }
        return true
    }

    private fun Result.successOnMain(value: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runCatching { success(value) }
        } else {
            Handler(Looper.getMainLooper()).post { runCatching { success(value) } }
        }
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
