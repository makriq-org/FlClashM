package com.follow.clashx.plugins

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File

private const val TAG = "SelfUpdateInstaller"
private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
private const val EXTRA_APK_PATH = "com.makriq.flclash.extra.SELF_UPDATE_APK_PATH"
private const val EXTRA_EXPECTED_PACKAGE =
    "com.makriq.flclash.extra.SELF_UPDATE_EXPECTED_PACKAGE"

internal enum class InstallStatusAction {
    NONE,
    LAUNCH_SYSTEM_INTENT,
    LAUNCH_INTERACTIVE_FALLBACK,
}

internal fun shouldUsePackageInstallerSession(
    sdkInt: Int,
    canRequestPackageInstalls: Boolean,
): Boolean = sdkInt >= Build.VERSION_CODES.S && canRequestPackageInstalls

internal fun installStatusAction(
    status: Int,
    hasSystemIntent: Boolean,
): InstallStatusAction = when (status) {
    PackageInstaller.STATUS_SUCCESS -> InstallStatusAction.NONE
    PackageInstaller.STATUS_PENDING_USER_ACTION ->
        if (hasSystemIntent) {
            InstallStatusAction.LAUNCH_SYSTEM_INTENT
        } else {
            InstallStatusAction.LAUNCH_INTERACTIVE_FALLBACK
        }
    PackageInstaller.STATUS_FAILURE_ABORTED ->
        if (hasSystemIntent) {
            InstallStatusAction.LAUNCH_SYSTEM_INTENT
        } else {
            InstallStatusAction.NONE
        }
    else ->
        if (hasSystemIntent) {
            InstallStatusAction.LAUNCH_SYSTEM_INTENT
        } else {
            InstallStatusAction.LAUNCH_INTERACTIVE_FALLBACK
        }
}

internal class SelfUpdateInstaller(
    context: Context,
) {
    private val appContext = context.applicationContext

    fun install(apkPath: String): Boolean {
        val apkFile = File(apkPath)
        if (!isSelfUpdateApk(apkFile)) {
            return false
        }

        val canRequestPackageInstalls = runCatching {
            appContext.packageManager.canRequestPackageInstalls()
        }.getOrDefault(false)
        if (!shouldUsePackageInstallerSession(
                sdkInt = Build.VERSION.SDK_INT,
                canRequestPackageInstalls = canRequestPackageInstalls,
            )
        ) {
            return launchInteractivePackageInstaller(appContext, apkFile)
        }

        return installWithPackageInstaller(apkFile) ||
            launchInteractivePackageInstaller(appContext, apkFile)
    }

    @Suppress("DEPRECATION")
    private fun isSelfUpdateApk(apkFile: File): Boolean {
        if (!apkFile.isFile || !apkFile.canRead()) {
            Log.w(TAG, "Self-update APK is missing or unreadable: ${apkFile.name}")
            return false
        }
        val archivePackage = runCatching {
            appContext.packageManager.getPackageArchiveInfo(apkFile.path, 0)
                ?.packageName
        }.getOrNull()
        if (archivePackage != appContext.packageName) {
            Log.w(
                TAG,
                "Rejected self-update APK for package $archivePackage",
            )
            return false
        }
        return true
    }

    private fun installWithPackageInstaller(apkFile: File): Boolean {
        val installer = appContext.packageManager.packageInstaller
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
                    session.openWrite(apkFile.name, 0, apkFile.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val statusIntent = Intent(
                    appContext,
                    SelfUpdateInstallReceiver::class.java,
                ).apply {
                    action = SelfUpdateInstallReceiver.action(appContext)
                    data = Uri.Builder()
                        .scheme("flclashm-self-update")
                        .authority(appContext.packageName)
                        .appendPath(createdSessionId.toString())
                        .build()
                    putExtra(EXTRA_APK_PATH, apkFile.path)
                    putExtra(EXTRA_EXPECTED_PACKAGE, appContext.packageName)
                }
                val statusPendingIntent = PendingIntent.getBroadcast(
                    appContext,
                    createdSessionId,
                    statusIntent,
                    // PackageInstaller must add status extras, so this cannot be
                    // immutable. The explicit non-exported receiver keeps the
                    // mutable PendingIntent scoped to this application.
                    PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(statusPendingIntent.intentSender)
                committed = true
            }
            true
        } catch (error: Exception) {
            Log.w(TAG, "PackageInstaller session failed; using fallback", error)
            false
        } finally {
            if (!committed) {
                sessionId?.let { id ->
                    runCatching { installer.abandonSession(id) }
                }
            }
        }
    }
}

class SelfUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action != action(context) ||
            intent.getStringExtra(EXTRA_EXPECTED_PACKAGE) != context.packageName
        ) {
            Log.w(TAG, "Ignored invalid self-update status callback")
            return
        }

        val apkFile = intent.getStringExtra(EXTRA_APK_PATH)?.let(::File)
        val systemIntent = intent.readSystemIntent()
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val statusMessage = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        Log.i(TAG, "Self-update status=$status message=$statusMessage")

        when (installStatusAction(status, systemIntent != null)) {
            InstallStatusAction.NONE -> Unit
            InstallStatusAction.LAUNCH_SYSTEM_INTENT -> {
                val launched = systemIntent != null && runCatching {
                    systemIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(systemIntent)
                }.isSuccess
                if (!launched) {
                    apkFile?.let {
                        launchInteractivePackageInstaller(context, it)
                    }
                }
            }
            InstallStatusAction.LAUNCH_INTERACTIVE_FALLBACK -> {
                apkFile?.let {
                    launchInteractivePackageInstaller(context, it)
                }
            }
        }
    }

    companion object {
        internal fun action(context: Context): String =
            "${context.packageName}.action.SELF_UPDATE_STATUS"
    }
}

@Suppress("DEPRECATION")
private fun Intent.readSystemIntent(): Intent? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
    } else {
        getParcelableExtra(Intent.EXTRA_INTENT)
    }

private fun launchInteractivePackageInstaller(
    context: Context,
    apkFile: File,
): Boolean {
    if (!apkFile.isFile || !apkFile.canRead()) {
        return false
    }
    return runCatching {
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileProvider",
            apkFile,
        )
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            clipData = ClipData.newRawUri(apkFile.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        true
    }.getOrElse { error ->
        Log.w(TAG, "Interactive package installer fallback failed", error)
        false
    }
}
