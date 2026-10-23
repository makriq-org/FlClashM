package com.follow.clashx.service

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.util.UUID

/** Permission mechanism only; Go decides when package inventory is needed. */
internal object InstalledAppsPermission {
    const val NAME = "com.android.permission.GET_INSTALLED_APPS"
    private val lock = Mutex()
    @Volatile private var token: String? = null
    @Volatile private var pending: CompletableDeferred<Boolean>? = null

    fun granted(context: Context): Boolean {
        val defined = try {
            context.packageManager.getPermissionInfo(NAME, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) { false }
        return !defined || context.checkSelfPermission(NAME) == PackageManager.PERMISSION_GRANTED
    }

    suspend fun ensure(context: Context) = lock.withLock {
        if (granted(context)) return@withLock
        // A headless recovery cannot interpret a ROM-filtered list as complete.
        val manager = context.getSystemService(ActivityManager::class.java)
        check(manager.runningAppProcesses.orEmpty().any {
            it.processName == context.packageName && it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }) { "Open FlClashM and allow access to installed applications for split tunneling" }
        val request = UUID.randomUUID().toString()
        val result = CompletableDeferred<Boolean>()
        token = request
        pending = result
        try {
            context.startActivity(Intent(context, InstalledAppsPermissionActivity::class.java)
                .putExtra("request", request).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            check(withTimeout(60_000L) { result.await() } && granted(context)) {
                "Installed applications permission is required for split tunneling"
            }
        } finally {
            token = null
            pending = null
        }
    }

    fun active(request: String?) = request != null && request == token
    fun complete(request: String?, granted: Boolean) {
        if (active(request)) pending?.complete(granted)
    }
}

/** Lives beside BackendHost so cancellation does not depend on Flutter IPC. */
class InstalledAppsPermissionActivity : Activity() {
    private val request get() = intent.getStringExtra("request")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!InstalledAppsPermission.active(request)) { finish(); return }
        if (InstalledAppsPermission.granted(this)) {
            InstalledAppsPermission.complete(request, true)
            finish()
        } else if (savedInstanceState == null) {
            requestPermissions(arrayOf(InstalledAppsPermission.NAME), 1)
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 1) {
            InstalledAppsPermission.complete(request, InstalledAppsPermission.granted(this))
            finish()
        }
    }

    override fun onDestroy() {
        if (isFinishing) InstalledAppsPermission.complete(request, false)
        super.onDestroy()
    }
}
