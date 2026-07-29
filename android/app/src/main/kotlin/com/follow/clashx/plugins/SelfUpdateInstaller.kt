package com.follow.clashx.plugins

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.follow.clashx.R
import java.io.File

private const val TAG = "SelfUpdateInstaller"
private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
private const val NOTIFICATION_CHANNEL_ID = "self_update_confirmation"
private const val NOTIFICATION_ID = 0x5345
private const val EXTRA_APK_PATH = "com.makriq.flclash.extra.SELF_UPDATE_APK_PATH"
private val SELF_UPDATE_LOCK = Any()

internal enum class InstallStatusAction {
    NONE,
    SYSTEM_CONFIRMATION,
    INTERACTIVE_FALLBACK,
}

internal enum class SelfUpdateInstallResult {
    ACCEPTED,
    INTERACTIVE_FALLBACK,
    REJECTED,
}

internal data class SessionSnapshot(
    val sessionId: Int,
    val packageName: String?,
    val committed: Boolean,
)

internal fun committedSelfUpdateSessionId(
    sessions: List<SessionSnapshot>,
    expectedPackage: String,
): Int? = sessions.firstOrNull {
    it.packageName == expectedPackage && it.committed
}?.sessionId

internal fun shouldUsePackageInstallerSession(
    sdkInt: Int,
    canRequestPackageInstalls: Boolean,
): Boolean = sdkInt >= Build.VERSION_CODES.S && canRequestPackageInstalls

internal fun installStatusAction(
    status: Int,
    hasSystemIntent: Boolean,
): InstallStatusAction = when (status) {
    PackageInstaller.STATUS_SUCCESS,
    PackageInstaller.STATUS_FAILURE_ABORTED,
    -> InstallStatusAction.NONE

    PackageInstaller.STATUS_PENDING_USER_ACTION ->
        if (hasSystemIntent) {
            InstallStatusAction.SYSTEM_CONFIRMATION
        } else {
            InstallStatusAction.INTERACTIVE_FALLBACK
        }

    else -> InstallStatusAction.NONE
}

internal class SelfUpdateInstaller(
    context: Context,
) {
    private val appContext = context.applicationContext

    fun install(apkPath: String): SelfUpdateInstallResult = synchronized(SELF_UPDATE_LOCK) {
        val apkFile = validatedSelfUpdateApk(appContext, apkPath)
            ?: return SelfUpdateInstallResult.REJECTED
        val canRequestPackageInstalls = runCatching {
            appContext.packageManager.canRequestPackageInstalls()
        }.getOrDefault(false)
        if (!shouldUsePackageInstallerSession(Build.VERSION.SDK_INT, canRequestPackageInstalls)) {
            return SelfUpdateInstallResult.INTERACTIVE_FALLBACK
        }

        when (installWithPackageInstaller(apkFile)) {
            SessionInstallResult.ACCEPTED -> SelfUpdateInstallResult.ACCEPTED
            SessionInstallResult.FALLBACK_ALLOWED -> SelfUpdateInstallResult.INTERACTIVE_FALLBACK
            SessionInstallResult.REJECTED -> SelfUpdateInstallResult.REJECTED
        }
    }

    fun installInteractively(
        activity: Activity,
        apkPath: String,
    ): Boolean {
        val apkFile = validatedSelfUpdateApk(appContext, apkPath) ?: return false
        return launchInteractiveInstaller(activity, apkFile)
    }

    private fun installWithPackageInstaller(apkFile: File): SessionInstallResult {
        val installer = appContext.packageManager.packageInstaller
        val sessionInfos = runCatching { installer.mySessions }.getOrElse { error ->
            Log.w(TAG, "Unable to inspect PackageInstaller sessions", error)
            return SessionInstallResult.REJECTED
        }
        val snapshots = sessionInfos.map {
            SessionSnapshot(it.sessionId, it.appPackageName, it.isCommitted)
        }
        committedSelfUpdateSessionId(snapshots, appContext.packageName)?.let { sessionId ->
            Log.i(TAG, "Self-update session $sessionId is already committed")
            return SessionInstallResult.ACCEPTED
        }
        snapshots
            .filter { it.packageName == appContext.packageName && !it.committed }
            .forEach { snapshot ->
                runCatching { installer.abandonSession(snapshot.sessionId) }
                    .onFailure { error ->
                        Log.w(TAG, "Unable to abandon stale session ${snapshot.sessionId}", error)
                        return SessionInstallResult.REJECTED
                    }
            }

        var sessionId: Int? = null
        var committed = false
        return try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            ).apply {
                setAppPackageName(appContext.packageName)
                setSize(apkFile.length())
                setInstallReason(PackageManager.INSTALL_REASON_USER)
                setRequireUserAction(
                    PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED,
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
                }
            }
            val createdSessionId = installer.createSession(params)
            sessionId = createdSessionId
            installer.openSession(createdSessionId).use { session ->
                apkFile.inputStream().use { input ->
                    session.openWrite("base.apk", 0, apkFile.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val callback = Intent(appContext, SelfUpdateInstallReceiver::class.java).apply {
                    action = SelfUpdateInstallReceiver.action(appContext)
                    putExtra(EXTRA_APK_PATH, apkFile.path)
                }
                val status = PendingIntent.getBroadcast(
                    appContext,
                    createdSessionId,
                    callback,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(status.intentSender)
                committed = true
            }
            SessionInstallResult.ACCEPTED
        } catch (error: Exception) {
            Log.w(TAG, "PackageInstaller session failed", error)
            SessionInstallResult.FALLBACK_ALLOWED
        } finally {
            if (!committed) {
                sessionId?.let { runCatching { installer.abandonSession(it) } }
            }
        }
    }

    private enum class SessionInstallResult {
        ACCEPTED,
        FALLBACK_ALLOWED,
        REJECTED,
    }
}

class SelfUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != action(context)) {
            Log.w(TAG, "Ignored unexpected self-update callback")
            return
        }

        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val sessionId = intent.getIntExtra(
            PackageInstaller.EXTRA_SESSION_ID,
            PackageInstaller.SessionInfo.INVALID_ID,
        )
        val systemIntent = intent.readSystemIntent()
        Log.i(
            TAG,
            "Self-update session=$sessionId status=$status " +
                "message=${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}",
        )

        when (installStatusAction(status, systemIntent != null)) {
            InstallStatusAction.NONE -> {
                SelfUpdateNotification.cancel(context)
                if (
                    status != PackageInstaller.STATUS_SUCCESS &&
                    status != PackageInstaller.STATUS_FAILURE_ABORTED
                ) {
                    Log.w(TAG, "Self-update session ended with terminal status $status")
                }
            }
            InstallStatusAction.SYSTEM_CONFIRMATION -> {
                val confirmation = checkNotNull(systemIntent)
                if (!SelfUpdateNotification.publish(context, confirmation, sessionId)) {
                    Log.w(TAG, "Unable to notify about required update confirmation")
                }
            }
            InstallStatusAction.INTERACTIVE_FALLBACK -> {
                val apkFile = intent.getStringExtra(EXTRA_APK_PATH)
                    ?.let { validatedSelfUpdateApk(context.applicationContext, it) }
                if (apkFile == null) {
                    Log.w(TAG, "Interactive fallback APK is unavailable")
                    return
                }
                val fallback = runCatching {
                    interactiveInstallerIntent(context, apkFile)
                }.getOrElse { error ->
                    Log.w(TAG, "Unable to create interactive installer fallback", error)
                    return
                }
                if (!SelfUpdateNotification.publish(context, fallback, sessionId)) {
                    Log.w(TAG, "Unable to notify about interactive installer fallback")
                }
            }
        }
    }

    companion object {
        internal fun action(context: Context): String =
            "${context.packageName}.action.SELF_UPDATE_STATUS"
    }
}

private object SelfUpdateNotification {
    fun publish(
        context: Context,
        activityIntent: Intent,
        requestCode: Int,
    ): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        ensureChannel(context, manager)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (!manager.areNotificationsEnabled()) {
            return false
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID)?.importance ==
            NotificationManager.IMPORTANCE_NONE
        ) {
            return false
        }

        return runCatching {
            val contentIntent = PendingIntent.getActivity(
                context,
                requestCode,
                activityIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(context.getString(R.string.self_update_confirmation_title))
                .setContentText(context.getString(R.string.self_update_confirmation_text))
                .setCategory(NotificationCompat.CATEGORY_SYSTEM)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(contentIntent)
                .build()
            manager.notify(NOTIFICATION_ID, notification)
            true
        }.getOrElse { error ->
            Log.w(TAG, "Unable to publish self-update confirmation", error)
            false
        }
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(
        context: Context,
        manager: NotificationManager,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                context.getString(R.string.self_update_confirmation_channel),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description =
                    context.getString(R.string.self_update_confirmation_channel_description)
            },
        )
    }
}

@Suppress("DEPRECATION")
private fun Intent.readSystemIntent(): Intent? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
    } else {
        getParcelableExtra(Intent.EXTRA_INTENT)
    }

@Suppress("DEPRECATION")
private fun validatedSelfUpdateApk(
    context: Context,
    apkPath: String,
): File? {
    val apkFile = runCatching { File(apkPath).canonicalFile }.getOrNull() ?: return null
    val filesRoot = runCatching { context.filesDir.canonicalFile }.getOrNull() ?: return null
    if (
        apkFile.parentFile == null ||
        !apkFile.path.startsWith("${filesRoot.path}${File.separator}") ||
        !apkFile.isFile ||
        !apkFile.canRead()
    ) {
        Log.w(TAG, "Self-update APK is outside private files or unreadable")
        return null
    }
    val archivePackage = runCatching {
        context.packageManager.getPackageArchiveInfo(apkFile.path, 0)?.packageName
    }.getOrNull()
    if (archivePackage != context.packageName) {
        Log.w(TAG, "Rejected self-update APK for package $archivePackage")
        return null
    }
    return apkFile
}

private fun interactiveInstallerIntent(
    context: Context,
    apkFile: File,
): Intent {
    val uri = FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileProvider",
        apkFile,
    )
    return Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
        setDataAndType(uri, APK_MIME_TYPE)
        clipData = ClipData.newRawUri(apkFile.name, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}

private fun launchInteractiveInstaller(
    activity: Activity,
    apkFile: File,
): Boolean = runCatching {
    launchActivity(activity, interactiveInstallerIntent(activity, apkFile))
}.getOrElse { error ->
    Log.w(TAG, "Unable to create interactive installer intent", error)
    false
}

private fun launchActivity(
    activity: Activity,
    intent: Intent,
): Boolean = runCatching {
    activity.startActivity(intent)
    true
}.getOrElse { error ->
    Log.w(TAG, "Interactive package installer failed", error)
    false
}
