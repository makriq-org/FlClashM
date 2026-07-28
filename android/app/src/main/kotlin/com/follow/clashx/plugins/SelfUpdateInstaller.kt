package com.follow.clashx.plugins

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.follow.clashx.R
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

private const val TAG = "SelfUpdateInstaller"
private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
private const val STORE_NAME = "self_update_installer"
private const val NOTIFICATION_CHANNEL_ID = "self_update_confirmation"
private const val NOTIFICATION_ID = 0x5345
private const val CALLBACK_SCHEME = "flclashm-self-update"
private const val EXTRA_EXPECTED_PACKAGE =
    "com.makriq.flclash.extra.SELF_UPDATE_EXPECTED_PACKAGE"
private const val EXTRA_OWN_SESSION_ID =
    "com.makriq.flclash.extra.SELF_UPDATE_SESSION_ID"
private val SELF_UPDATE_LOCK = Any()

internal enum class InstallStatusAction {
    NONE,
    SYSTEM_CONFIRMATION,
    INTERACTIVE_FALLBACK,
}

internal enum class ContinuationKind {
    SYSTEM_CONFIRMATION,
    INTERACTIVE_FALLBACK,
}

internal enum class ContinuationResult {
    LAUNCHED,
    NOTIFIED,
    PERSISTED,
}

internal data class PendingContinuation(
    val token: String,
    val sessionId: Int,
    val kind: ContinuationKind,
    val apkPath: String,
    val apkSha256: String,
    val systemIntentUri: String?,
)

internal interface PendingContinuationStore {
    fun load(): PendingContinuation?

    fun save(continuation: PendingContinuation): Boolean

    fun clear()
}

internal interface ContinuationDelivery {
    fun launch(continuation: PendingContinuation): Boolean

    fun notify(token: String): Boolean

    fun cancelNotification()
}

/**
 * Persist-first state machine shared by the receiver, notification Activity and
 * MainActivity. A failed launch never consumes the continuation.
 */
internal class PendingContinuationCoordinator(
    private val store: PendingContinuationStore,
    private val delivery: ContinuationDelivery,
) {
    @Synchronized
    fun accept(
        continuation: PendingContinuation,
        hasResumedActivity: Boolean,
        notificationsAllowed: Boolean,
    ): ContinuationResult {
        check(store.save(continuation)) {
            "Unable to persist self-update continuation"
        }
        if (hasResumedActivity && launchStored(continuation.token)) {
            return ContinuationResult.LAUNCHED
        }
        if (notificationsAllowed && delivery.notify(continuation.token)) {
            return ContinuationResult.NOTIFIED
        }
        return ContinuationResult.PERSISTED
    }

    @Synchronized
    fun recover(
        token: String? = null,
        notificationsAllowed: Boolean = false,
    ): ContinuationResult? {
        val continuation = store.load() ?: return null
        if (token != null && continuation.token != token) {
            return null
        }
        if (launchStored(continuation.token)) {
            return ContinuationResult.LAUNCHED
        }
        if (notificationsAllowed && delivery.notify(continuation.token)) {
            return ContinuationResult.NOTIFIED
        }
        return ContinuationResult.PERSISTED
    }

    private fun launchStored(token: String): Boolean {
        val continuation = store.load()
        if (continuation == null || continuation.token != token) {
            return false
        }
        if (!delivery.launch(continuation)) {
            return false
        }
        store.clear()
        delivery.cancelNotification()
        return true
    }
}

internal data class SessionSnapshot(
    val sessionId: Int,
    val packageName: String?,
    val committed: Boolean,
    val createdMillis: Long,
)

internal data class SessionReconciliation(
    val blockingCommittedSessionId: Int?,
    val abandonSessionIds: List<Int>,
)

/**
 * PackageInstaller session metadata has no APK digest or caller tag. Therefore
 * any committed session owned by this installer and targeting this package is
 * treated as the single active self-update, regardless of the new file path.
 */
internal fun reconcileSelfUpdateSessions(
    sessions: List<SessionSnapshot>,
    expectedPackage: String,
): SessionReconciliation {
    val selfSessions = sessions.filter { it.packageName == expectedPackage }
    val committed = selfSessions
        .filter(SessionSnapshot::committed)
        .maxWithOrNull(
            compareBy<SessionSnapshot> { it.createdMillis }
                .thenBy { it.sessionId },
        )
    return SessionReconciliation(
        blockingCommittedSessionId = committed?.sessionId,
        abandonSessionIds = selfSessions
            .filterNot(SessionSnapshot::committed)
            .map(SessionSnapshot::sessionId),
    )
}

internal fun shouldUsePackageInstallerSession(
    sdkInt: Int,
    canRequestPackageInstalls: Boolean,
): Boolean = sdkInt >= Build.VERSION_CODES.S && canRequestPackageInstalls

internal fun installStatusAction(
    status: Int,
    hasTrustedSystemIntent: Boolean,
): InstallStatusAction = when (status) {
    PackageInstaller.STATUS_SUCCESS -> InstallStatusAction.NONE
    PackageInstaller.STATUS_FAILURE_ABORTED -> InstallStatusAction.NONE
    PackageInstaller.STATUS_PENDING_USER_ACTION ->
        if (hasTrustedSystemIntent) {
            InstallStatusAction.SYSTEM_CONFIRMATION
        } else {
            InstallStatusAction.INTERACTIVE_FALLBACK
        }
    else ->
        if (hasTrustedSystemIntent) {
            InstallStatusAction.SYSTEM_CONFIRMATION
        } else {
            InstallStatusAction.INTERACTIVE_FALLBACK
        }
}

private data class ActiveSessionRecord(
    val sessionId: Int,
    val nonce: String,
    val apkPath: String,
    val apkSha256: String,
    val committed: Boolean,
    val callbackHandled: Boolean,
)

private class SelfUpdateStateStore(
    context: Context,
) : PendingContinuationStore {
    private val preferences =
        context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE)

    override fun load(): PendingContinuation? {
        val token = preferences.getString(KEY_CONTINUATION_TOKEN, null) ?: return null
        val kind = preferences.getString(KEY_CONTINUATION_KIND, null)
            ?.let { runCatching { ContinuationKind.valueOf(it) }.getOrNull() }
            ?: return null
        return PendingContinuation(
            token = token,
            sessionId = preferences.getInt(
                KEY_CONTINUATION_SESSION_ID,
                PackageInstaller.SessionInfo.INVALID_ID,
            ),
            kind = kind,
            apkPath = preferences.getString(KEY_CONTINUATION_APK_PATH, "") ?: "",
            apkSha256 = preferences.getString(KEY_CONTINUATION_APK_SHA256, "") ?: "",
            systemIntentUri = preferences.getString(KEY_CONTINUATION_SYSTEM_INTENT, null),
        )
    }

    override fun save(continuation: PendingContinuation): Boolean =
        preferences.edit()
            .putString(KEY_CONTINUATION_TOKEN, continuation.token)
            .putInt(KEY_CONTINUATION_SESSION_ID, continuation.sessionId)
            .putString(KEY_CONTINUATION_KIND, continuation.kind.name)
            .putString(KEY_CONTINUATION_APK_PATH, continuation.apkPath)
            .putString(KEY_CONTINUATION_APK_SHA256, continuation.apkSha256)
            .putString(KEY_CONTINUATION_SYSTEM_INTENT, continuation.systemIntentUri)
            .commit()

    override fun clear() {
        preferences.edit()
            .remove(KEY_CONTINUATION_TOKEN)
            .remove(KEY_CONTINUATION_SESSION_ID)
            .remove(KEY_CONTINUATION_KIND)
            .remove(KEY_CONTINUATION_APK_PATH)
            .remove(KEY_CONTINUATION_APK_SHA256)
            .remove(KEY_CONTINUATION_SYSTEM_INTENT)
            .commit()
    }

    fun loadSession(): ActiveSessionRecord? {
        val sessionId = preferences.getInt(
            KEY_SESSION_ID,
            PackageInstaller.SessionInfo.INVALID_ID,
        )
        val nonce = preferences.getString(KEY_SESSION_NONCE, null)
        if (sessionId == PackageInstaller.SessionInfo.INVALID_ID || nonce == null) {
            return null
        }
        return ActiveSessionRecord(
            sessionId = sessionId,
            nonce = nonce,
            apkPath = preferences.getString(KEY_SESSION_APK_PATH, "") ?: "",
            apkSha256 = preferences.getString(KEY_SESSION_APK_SHA256, "") ?: "",
            committed = preferences.getBoolean(KEY_SESSION_COMMITTED, false),
            callbackHandled = preferences.getBoolean(KEY_SESSION_CALLBACK_HANDLED, false),
        )
    }

    fun saveSession(record: ActiveSessionRecord): Boolean =
        preferences.edit()
            .putInt(KEY_SESSION_ID, record.sessionId)
            .putString(KEY_SESSION_NONCE, record.nonce)
            .putString(KEY_SESSION_APK_PATH, record.apkPath)
            .putString(KEY_SESSION_APK_SHA256, record.apkSha256)
            .putBoolean(KEY_SESSION_COMMITTED, record.committed)
            .putBoolean(KEY_SESSION_CALLBACK_HANDLED, record.callbackHandled)
            .commit()

    fun clearSession(sessionId: Int? = null) {
        val current = loadSession()
        if (sessionId != null && current?.sessionId != sessionId) {
            return
        }
        preferences.edit()
            .remove(KEY_SESSION_ID)
            .remove(KEY_SESSION_NONCE)
            .remove(KEY_SESSION_APK_PATH)
            .remove(KEY_SESSION_APK_SHA256)
            .remove(KEY_SESSION_COMMITTED)
            .remove(KEY_SESSION_CALLBACK_HANDLED)
            .commit()
    }

    fun markCallbackHandled(sessionId: Int) {
        if (loadSession()?.sessionId == sessionId) {
            preferences.edit().putBoolean(KEY_SESSION_CALLBACK_HANDLED, true).commit()
        }
    }

    companion object {
        private const val KEY_SESSION_ID = "session_id"
        private const val KEY_SESSION_NONCE = "session_nonce"
        private const val KEY_SESSION_APK_PATH = "session_apk_path"
        private const val KEY_SESSION_APK_SHA256 = "session_apk_sha256"
        private const val KEY_SESSION_COMMITTED = "session_committed"
        private const val KEY_SESSION_CALLBACK_HANDLED = "session_callback_handled"
        private const val KEY_CONTINUATION_TOKEN = "continuation_token"
        private const val KEY_CONTINUATION_SESSION_ID = "continuation_session_id"
        private const val KEY_CONTINUATION_KIND = "continuation_kind"
        private const val KEY_CONTINUATION_APK_PATH = "continuation_apk_path"
        private const val KEY_CONTINUATION_APK_SHA256 = "continuation_apk_sha256"
        private const val KEY_CONTINUATION_SYSTEM_INTENT = "continuation_system_intent"
    }
}

internal object SelfUpdateForegroundActivity {
    private var resumedActivity = WeakReference<Activity>(null)

    @Synchronized
    fun onResumed(activity: Activity) {
        resumedActivity = WeakReference(activity)
    }

    @Synchronized
    fun onPaused(activity: Activity) {
        if (resumedActivity.get() === activity) {
            resumedActivity.clear()
        }
    }

    @Synchronized
    fun current(): Activity? =
        resumedActivity.get()?.takeUnless { it.isFinishing || it.isDestroyed }
}

private class AndroidContinuationDelivery(
    private val appContext: Context,
    private val activityProvider: () -> Activity?,
) : ContinuationDelivery {
    override fun launch(continuation: PendingContinuation): Boolean {
        val activity = activityProvider() ?: return false
        return when (continuation.kind) {
            ContinuationKind.SYSTEM_CONFIRMATION ->
                launchStoredSystemConfirmation(activity, continuation)
            ContinuationKind.INTERACTIVE_FALLBACK ->
                launchStoredInteractiveFallback(activity, continuation)
        }
    }

    override fun notify(token: String): Boolean =
        SelfUpdateNotification.publish(appContext, token)

    override fun cancelNotification() {
        SelfUpdateNotification.cancel(appContext)
    }
}

private object SelfUpdateRuntime {
    fun coordinator(
        context: Context,
        activityProvider: () -> Activity? = SelfUpdateForegroundActivity::current,
    ): PendingContinuationCoordinator {
        val appContext = context.applicationContext
        return PendingContinuationCoordinator(
            store = SelfUpdateStateStore(appContext),
            delivery = AndroidContinuationDelivery(appContext, activityProvider),
        )
    }

    fun accept(context: Context, continuation: PendingContinuation): ContinuationResult {
        val activity = SelfUpdateForegroundActivity.current()
        return coordinator(context) {
            activity?.takeUnless { it.isFinishing || it.isDestroyed }
        }.accept(
            continuation = continuation,
            hasResumedActivity = activity != null,
            notificationsAllowed = SelfUpdateNotification.canNotify(context),
        )
    }
}

internal object SelfUpdateContinuationController {
    fun resumePending(
        activity: Activity,
        token: String? = null,
    ): Boolean = synchronized(SELF_UPDATE_LOCK) {
        val result = SelfUpdateRuntime.coordinator(activity) { activity }
            .recover(token = token)
        result == ContinuationResult.LAUNCHED
    }
}

internal class SelfUpdateInstaller(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val stateStore = SelfUpdateStateStore(appContext)

    fun install(apkPath: String): Boolean = synchronized(SELF_UPDATE_LOCK) {
        val apkFile = validatedSelfUpdateApk(File(apkPath)) ?: return false
        val apkSha256 = apkFile.sha256()

        stateStore.load()?.let { pending ->
            val existingActivity = SelfUpdateForegroundActivity.current()
            SelfUpdateRuntime.coordinator(appContext) {
                existingActivity
            }.recover(
                notificationsAllowed = SelfUpdateNotification.canNotify(appContext),
            )
            return true
        }

        val canRequestPackageInstalls = runCatching {
            appContext.packageManager.canRequestPackageInstalls()
        }.getOrDefault(false)
        if (!shouldUsePackageInstallerSession(
                sdkInt = Build.VERSION.SDK_INT,
                canRequestPackageInstalls = canRequestPackageInstalls,
            )
        ) {
            return requestInteractiveFallback(apkFile, apkSha256)
        }

        when (installWithPackageInstaller(apkFile, apkSha256)) {
            SessionInstallResult.ACCEPTED -> true
            SessionInstallResult.FALLBACK_ALLOWED ->
                requestInteractiveFallback(apkFile, apkSha256)
            SessionInstallResult.REJECTED -> false
        }
    }

    @Suppress("DEPRECATION")
    private fun validatedSelfUpdateApk(apkFile: File): File? {
        val canonicalFile = runCatching { apkFile.canonicalFile }.getOrNull() ?: return null
        val filesRoot = runCatching { appContext.filesDir.canonicalFile }.getOrNull() ?: return null
        if (
            canonicalFile.parentFile == null ||
            !canonicalFile.path.startsWith("${filesRoot.path}${File.separator}") ||
            !canonicalFile.isFile ||
            !canonicalFile.canRead()
        ) {
            Log.w(TAG, "Self-update APK is outside private files or unreadable")
            return null
        }
        val archivePackage = runCatching {
            appContext.packageManager.getPackageArchiveInfo(canonicalFile.path, 0)
                ?.packageName
        }.getOrNull()
        if (archivePackage != appContext.packageName) {
            Log.w(TAG, "Rejected self-update APK for package $archivePackage")
            return null
        }
        return canonicalFile
    }

    private fun installWithPackageInstaller(
        apkFile: File,
        apkSha256: String,
    ): SessionInstallResult {
        val installer = appContext.packageManager.packageInstaller
        val sessionInfos = runCatching { installer.mySessions }.getOrElse { error ->
            Log.w(TAG, "Unable to reconcile PackageInstaller sessions", error)
            return SessionInstallResult.REJECTED
        }
        val reconciliation = reconcileSelfUpdateSessions(
            sessions = sessionInfos.map {
                SessionSnapshot(
                    sessionId = it.sessionId,
                    packageName = it.appPackageName,
                    committed = it.isCommitted,
                    createdMillis = it.createdMillis,
                )
            },
            expectedPackage = appContext.packageName,
        )
        reconciliation.abandonSessionIds.forEach { sessionId ->
            runCatching { installer.abandonSession(sessionId) }
                .onFailure { error ->
                    Log.w(TAG, "Unable to abandon incomplete session $sessionId", error)
                    return SessionInstallResult.REJECTED
                }
        }
        reconciliation.blockingCommittedSessionId?.let { sessionId ->
            Log.i(TAG, "Reusing committed self-update session $sessionId")
            return SessionInstallResult.ACCEPTED
        }
        stateStore.clearSession()

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
            val nonce = randomToken()
            val activeRecord = ActiveSessionRecord(
                sessionId = createdSessionId,
                nonce = nonce,
                apkPath = apkFile.path,
                apkSha256 = apkSha256,
                committed = false,
                callbackHandled = false,
            )
            check(stateStore.saveSession(activeRecord)) {
                "Unable to persist PackageInstaller session"
            }
            installer.openSession(createdSessionId).use { session ->
                apkFile.inputStream().use { input ->
                    session.openWrite("base.apk", 0, apkFile.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val statusIntent = Intent(
                    appContext,
                    SelfUpdateInstallReceiver::class.java,
                ).apply {
                    action = SelfUpdateInstallReceiver.action(appContext)
                    data = callbackUri(appContext, createdSessionId, nonce)
                    putExtra(EXTRA_OWN_SESSION_ID, createdSessionId)
                    putExtra(EXTRA_EXPECTED_PACKAGE, appContext.packageName)
                }
                val statusPendingIntent = PendingIntent.getBroadcast(
                    appContext,
                    createdSessionId,
                    statusIntent,
                    // PackageInstaller adds status extras to this explicit,
                    // non-exported receiver. Base action/data and the persisted
                    // nonce make the required mutable token non-spoofable.
                    PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(statusPendingIntent.intentSender)
                committed = true
                check(stateStore.saveSession(activeRecord.copy(committed = true))) {
                    "Unable to persist committed PackageInstaller session"
                }
            }
            SessionInstallResult.ACCEPTED
        } catch (error: Exception) {
            Log.w(TAG, "PackageInstaller session failed", error)
            SessionInstallResult.FALLBACK_ALLOWED
        } finally {
            if (!committed) {
                sessionId?.let { id ->
                    runCatching { installer.abandonSession(id) }
                    stateStore.clearSession(id)
                }
            }
        }
    }

    private fun requestInteractiveFallback(
        apkFile: File,
        apkSha256: String,
    ): Boolean = runCatching {
        SelfUpdateRuntime.accept(
            appContext,
            PendingContinuation(
                token = randomToken(),
                sessionId = PackageInstaller.SessionInfo.INVALID_ID,
                kind = ContinuationKind.INTERACTIVE_FALLBACK,
                apkPath = apkFile.path,
                apkSha256 = apkSha256,
                systemIntentUri = null,
            ),
        )
        true
    }.getOrElse { error ->
        Log.w(TAG, "Unable to persist interactive installer fallback", error)
        false
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
        synchronized(SELF_UPDATE_LOCK) {
            val stateStore = SelfUpdateStateStore(context)
            val callbackIdentity = intent.callbackIdentity(context)
            val sessionRecord = stateStore.loadSession()
            if (
                intent.action != action(context) ||
                intent.getStringExtra(EXTRA_EXPECTED_PACKAGE) != context.packageName ||
                callbackIdentity == null ||
                intent.getIntExtra(
                    EXTRA_OWN_SESSION_ID,
                    PackageInstaller.SessionInfo.INVALID_ID,
                ) != callbackIdentity.first ||
                sessionRecord?.sessionId != callbackIdentity.first ||
                sessionRecord.nonce != callbackIdentity.second
            ) {
                Log.w(TAG, "Ignored invalid self-update status callback")
                return@synchronized
            }

            val sessionId = callbackIdentity.first
            val status = intent.getIntExtra(
                PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_FAILURE,
            )
            val statusMessage = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            Log.i(TAG, "Self-update session=$sessionId status=$status message=$statusMessage")

            if (status == PackageInstaller.STATUS_SUCCESS) {
                stateStore.clear()
                stateStore.clearSession(sessionId)
                SelfUpdateNotification.cancel(context)
                return@synchronized
            }

            val trustedSystemIntent = intent.readSystemIntent()
                ?.let { makeExplicitTrustedSystemIntent(context, it) }
            val action = installStatusAction(status, trustedSystemIntent != null)
            if (action == InstallStatusAction.NONE) {
                stateStore.clear()
                stateStore.clearSession(sessionId)
                SelfUpdateNotification.cancel(context)
                return@synchronized
            }

            if (sessionRecord.callbackHandled) {
                stateStore.load()
                    ?.takeIf { it.sessionId == sessionId }
                    ?.let {
                        SelfUpdateRuntime.accept(context, it)
                    }
                return@synchronized
            }

            val continuation = when (action) {
                InstallStatusAction.SYSTEM_CONFIRMATION -> PendingContinuation(
                    token = randomToken(),
                    sessionId = sessionId,
                    kind = ContinuationKind.SYSTEM_CONFIRMATION,
                    apkPath = sessionRecord.apkPath,
                    apkSha256 = sessionRecord.apkSha256,
                    systemIntentUri = trustedSystemIntent?.toUri(Intent.URI_INTENT_SCHEME),
                )
                InstallStatusAction.INTERACTIVE_FALLBACK -> PendingContinuation(
                    token = randomToken(),
                    sessionId = sessionId,
                    kind = ContinuationKind.INTERACTIVE_FALLBACK,
                    apkPath = sessionRecord.apkPath,
                    apkSha256 = sessionRecord.apkSha256,
                    systemIntentUri = null,
                )
                InstallStatusAction.NONE -> return@synchronized
            }

            runCatching {
                SelfUpdateRuntime.accept(context, continuation)
                stateStore.markCallbackHandled(sessionId)
                if (status != PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    stateStore.clearSession(sessionId)
                }
            }.onFailure { error ->
                Log.e(TAG, "Unable to preserve self-update confirmation", error)
            }
        }
    }

    companion object {
        internal fun action(context: Context): String =
            "${context.packageName}.action.SELF_UPDATE_STATUS"
    }
}

/**
 * Direct target of the notification PendingIntent. It is non-exported and the
 * unguessable token must match app-private persisted state before anything is
 * launched.
 */
class SelfUpdateConfirmationActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val token = intent.continuationToken(this)
        if (token == null || !SelfUpdateContinuationController.resumePending(this, token)) {
            Log.w(TAG, "Ignored invalid or stale self-update notification")
        }
        finish()
    }
}

private object SelfUpdateNotification {
    fun canNotify(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        ensureChannel(context, manager)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (!manager.areNotificationsEnabled()) {
            return false
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID)?.importance !=
                NotificationManager.IMPORTANCE_NONE
        } else {
            true
        }
    }

    fun publish(context: Context, token: String): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!canNotify(context)) {
            return false
        }
        val activityIntent = Intent(
            context,
            SelfUpdateConfirmationActivity::class.java,
        ).apply {
            data = continuationUri(context, token)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            token.hashCode(),
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
        return runCatching {
            manager.notify(NOTIFICATION_ID, notification)
            true
        }.getOrElse { error ->
            Log.w(TAG, "Unable to publish self-update confirmation", error)
            false
        }
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)
            ?.cancel(NOTIFICATION_ID)
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

private fun makeExplicitTrustedSystemIntent(
    context: Context,
    source: Intent,
): Intent? {
    val candidate = Intent(source).apply {
        selector = null
    }
    val resolved = context.packageManager.resolveActivity(
        candidate,
        PackageManager.MATCH_DEFAULT_ONLY,
    )?.activityInfo ?: return null
    val flags = resolved.applicationInfo.flags
    val isSystemPackage =
        flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
    if (!isSystemPackage || !resolved.exported) {
        Log.w(TAG, "Rejected non-system package confirmation intent")
        return null
    }
    candidate.component = ComponentName(resolved.packageName, resolved.name)
    return candidate
}

private fun launchStoredSystemConfirmation(
    activity: Activity,
    continuation: PendingContinuation,
): Boolean {
    val uri = continuation.systemIntentUri ?: return false
    val parsed = runCatching {
        Intent.parseUri(uri, Intent.URI_INTENT_SCHEME)
    }.getOrNull() ?: return false
    val trusted = makeExplicitTrustedSystemIntent(activity, parsed) ?: return false
    return runCatching {
        activity.startActivity(trusted)
        true
    }.getOrElse { error ->
        Log.w(TAG, "System package confirmation failed", error)
        false
    }
}

private fun launchStoredInteractiveFallback(
    activity: Activity,
    continuation: PendingContinuation,
): Boolean {
    val appContext = activity.applicationContext
    val apkFile = runCatching { File(continuation.apkPath).canonicalFile }.getOrNull()
        ?: return false
    val filesRoot = runCatching { appContext.filesDir.canonicalFile }.getOrNull()
        ?: return false
    if (
        !apkFile.path.startsWith("${filesRoot.path}${File.separator}") ||
        !apkFile.isFile ||
        !apkFile.canRead() ||
        apkFile.sha256() != continuation.apkSha256
    ) {
        Log.w(TAG, "Rejected changed or unavailable fallback APK")
        return false
    }
    @Suppress("DEPRECATION")
    val archivePackage = runCatching {
        appContext.packageManager.getPackageArchiveInfo(apkFile.path, 0)?.packageName
    }.getOrNull()
    if (archivePackage != appContext.packageName) {
        Log.w(TAG, "Rejected fallback APK for package $archivePackage")
        return false
    }
    return runCatching {
        val uri = FileProvider.getUriForFile(
            appContext,
            "${appContext.packageName}.fileProvider",
            apkFile,
        )
        val installerIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            clipData = ClipData.newRawUri(apkFile.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(installerIntent)
        true
    }.getOrElse { error ->
        Log.w(TAG, "Interactive package installer fallback failed", error)
        false
    }
}

private fun callbackUri(
    context: Context,
    sessionId: Int,
    nonce: String,
): Uri = Uri.Builder()
    .scheme(CALLBACK_SCHEME)
    .authority(context.packageName)
    .appendPath("status")
    .appendPath(sessionId.toString())
    .appendPath(nonce)
    .build()

private fun Intent.callbackIdentity(context: Context): Pair<Int, String>? {
    val callbackUri = data ?: return null
    if (
        callbackUri.scheme != CALLBACK_SCHEME ||
        callbackUri.authority != context.packageName ||
        callbackUri.pathSegments.size != 3 ||
        callbackUri.pathSegments[0] != "status"
    ) {
        return null
    }
    val sessionId = callbackUri.pathSegments[1].toIntOrNull() ?: return null
    val nonce = callbackUri.pathSegments[2].takeIf(String::isNotBlank) ?: return null
    return sessionId to nonce
}

private fun continuationUri(context: Context, token: String): Uri =
    Uri.Builder()
        .scheme(CALLBACK_SCHEME)
        .authority(context.packageName)
        .appendPath("continue")
        .appendPath(token)
        .build()

private fun Intent.continuationToken(context: Context): String? {
    val continuationUri = data ?: return null
    if (
        continuationUri.scheme != CALLBACK_SCHEME ||
        continuationUri.authority != context.packageName ||
        continuationUri.pathSegments.size != 2 ||
        continuationUri.pathSegments[0] != "continue"
    ) {
        return null
    }
    return continuationUri.pathSegments[1].takeIf(String::isNotBlank)
}

private fun randomToken(): String {
    val bytes = ByteArray(24)
    SecureRandom().nextBytes(bytes)
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
}

private fun File.sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) {
                break
            }
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString(separator = "") { "%02x".format(it) }
}
