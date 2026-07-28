package com.follow.clashx.plugins

import android.content.pm.PackageInstaller
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SelfUpdateInstallerTest {
    @Test
    fun `session is used only on Android 12 plus with trusted source access`() {
        assertFalse(
            shouldUsePackageInstallerSession(
                sdkInt = 30,
                canRequestPackageInstalls = true,
            ),
        )
        assertFalse(
            shouldUsePackageInstallerSession(
                sdkInt = 31,
                canRequestPackageInstalls = false,
            ),
        )
        assertTrue(
            shouldUsePackageInstallerSession(
                sdkInt = 31,
                canRequestPackageInstalls = true,
            ),
        )
        assertTrue(
            shouldUsePackageInstallerSession(
                sdkInt = 36,
                canRequestPackageInstalls = true,
            ),
        )
    }

    @Test
    fun `pending user action keeps the supplied system confirmation`() {
        assertEquals(
            InstallStatusAction.SYSTEM_CONFIRMATION,
            installStatusAction(
                status = PackageInstaller.STATUS_PENDING_USER_ACTION,
                hasTrustedSystemIntent = true,
            ),
        )
    }

    @Test
    fun `pending user action without trusted intent uses interactive fallback`() {
        assertEquals(
            InstallStatusAction.INTERACTIVE_FALLBACK,
            installStatusAction(
                status = PackageInstaller.STATUS_PENDING_USER_ACTION,
                hasTrustedSystemIntent = false,
            ),
        )
    }

    @Test
    fun `user cancellation does not reopen the installer`() {
        assertEquals(
            InstallStatusAction.NONE,
            installStatusAction(
                status = PackageInstaller.STATUS_FAILURE_ABORTED,
                hasTrustedSystemIntent = false,
            ),
        )
        assertEquals(
            InstallStatusAction.NONE,
            installStatusAction(
                status = PackageInstaller.STATUS_FAILURE_ABORTED,
                hasTrustedSystemIntent = true,
            ),
        )
    }

    @Test
    fun `OEM and generic failures preserve the interactive fallback`() {
        val failureStatuses = listOf(
            PackageInstaller.STATUS_FAILURE,
            PackageInstaller.STATUS_FAILURE_BLOCKED,
            PackageInstaller.STATUS_FAILURE_CONFLICT,
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
            PackageInstaller.STATUS_FAILURE_INVALID,
            PackageInstaller.STATUS_FAILURE_STORAGE,
        )

        failureStatuses.forEach { status ->
            assertEquals(
                InstallStatusAction.INTERACTIVE_FALLBACK,
                installStatusAction(
                    status = status,
                    hasTrustedSystemIntent = false,
                ),
            )
        }
    }

    @Test
    fun `committed self session blocks another install and incomplete ones are abandoned`() {
        val reconciliation = reconcileSelfUpdateSessions(
            sessions = listOf(
                SessionSnapshot(
                    sessionId = 10,
                    packageName = "com.makriq.flclash",
                    committed = false,
                    createdMillis = 100,
                ),
                SessionSnapshot(
                    sessionId = 11,
                    packageName = "com.makriq.flclash",
                    committed = true,
                    createdMillis = 101,
                ),
                SessionSnapshot(
                    sessionId = 12,
                    packageName = "other.package",
                    committed = false,
                    createdMillis = 102,
                ),
            ),
            expectedPackage = "com.makriq.flclash",
        )

        assertEquals(11, reconciliation.blockingCommittedSessionId)
        assertEquals(listOf(10), reconciliation.abandonSessionIds)
    }

    @Test
    fun `newest committed self session wins deterministic reconciliation`() {
        val reconciliation = reconcileSelfUpdateSessions(
            sessions = listOf(
                SessionSnapshot(20, "com.makriq.flclash", true, 200),
                SessionSnapshot(21, "com.makriq.flclash", true, 201),
                SessionSnapshot(22, "com.makriq.flclash", true, 201),
            ),
            expectedPackage = "com.makriq.flclash",
        )

        assertEquals(22, reconciliation.blockingCommittedSessionId)
        assertEquals(emptyList(), reconciliation.abandonSessionIds)
    }

    @Test
    fun `foreground callback persists before launching and consumes after success`() {
        val events = mutableListOf<String>()
        val store = FakeStore(events = events)
        val delivery = FakeDelivery(
            launchSucceeds = true,
            events = events,
        )
        val coordinator = PendingContinuationCoordinator(store, delivery)
        val continuation = continuation()

        val result = coordinator.accept(
            continuation = continuation,
            hasResumedActivity = true,
            notificationsAllowed = true,
        )

        assertEquals(ContinuationResult.LAUNCHED, result)
        assertEquals(
            listOf("save", "load", "launch", "clear", "cancel"),
            events,
        )
        assertNull(store.value)
        assertEquals(0, delivery.notifications)
        assertEquals(1, delivery.cancelCalls)
    }

    @Test
    fun `background callback publishes notification without launching activity`() {
        val store = FakeStore()
        val delivery = FakeDelivery(launchSucceeds = true, notifySucceeds = true)
        val coordinator = PendingContinuationCoordinator(store, delivery)
        val continuation = continuation()

        val result = coordinator.accept(
            continuation = continuation,
            hasResumedActivity = false,
            notificationsAllowed = true,
        )

        assertEquals(ContinuationResult.NOTIFIED, result)
        assertEquals(continuation, store.value)
        assertEquals(0, delivery.launches)
        assertEquals(1, delivery.notifications)
    }

    @Test
    fun `notification denial keeps continuation until next foreground`() {
        val store = FakeStore()
        val delivery = FakeDelivery(launchSucceeds = true)
        val coordinator = PendingContinuationCoordinator(store, delivery)
        val continuation = continuation()

        val accepted = coordinator.accept(
            continuation = continuation,
            hasResumedActivity = false,
            notificationsAllowed = false,
        )
        assertEquals(ContinuationResult.PERSISTED, accepted)
        assertEquals(continuation, store.value)
        assertEquals(0, delivery.launches)
        assertEquals(0, delivery.notifications)

        val recovered = coordinator.recover()
        assertEquals(ContinuationResult.LAUNCHED, recovered)
        assertNull(store.value)
        assertEquals(1, delivery.launches)
    }

    @Test
    fun `failed foreground launch remains durable and falls back to notification`() {
        val store = FakeStore()
        val delivery = FakeDelivery(launchSucceeds = false, notifySucceeds = true)
        val coordinator = PendingContinuationCoordinator(store, delivery)
        val continuation = continuation()

        val result = coordinator.accept(
            continuation = continuation,
            hasResumedActivity = true,
            notificationsAllowed = true,
        )

        assertEquals(ContinuationResult.NOTIFIED, result)
        assertEquals(continuation, store.value)
        assertEquals(1, delivery.launches)
        assertEquals(1, delivery.notifications)
        assertEquals(0, delivery.cancelCalls)
    }

    @Test
    fun `notification token cannot consume a different continuation`() {
        val store = FakeStore().apply { value = continuation(token = "expected") }
        val delivery = FakeDelivery(launchSucceeds = true)
        val coordinator = PendingContinuationCoordinator(store, delivery)

        assertNull(coordinator.recover(token = "spoofed"))
        assertEquals("expected", store.value?.token)
        assertEquals(0, delivery.launches)
    }

    private fun continuation(token: String = "token") = PendingContinuation(
        token = token,
        sessionId = 42,
        kind = ContinuationKind.SYSTEM_CONFIRMATION,
        apkPath = "/private/update.apk",
        apkSha256 = "a".repeat(64),
        systemIntentUri = "intent:#Intent;end",
    )

    private class FakeStore(
        private val events: MutableList<String> = mutableListOf(),
    ) : PendingContinuationStore {
        var value: PendingContinuation? = null

        override fun load(): PendingContinuation? {
            events += "load"
            return value
        }

        override fun save(continuation: PendingContinuation): Boolean {
            events += "save"
            value = continuation
            return true
        }

        override fun clear() {
            events += "clear"
            value = null
        }
    }

    private class FakeDelivery(
        private val launchSucceeds: Boolean,
        private val notifySucceeds: Boolean = false,
        private val events: MutableList<String> = mutableListOf(),
    ) : ContinuationDelivery {
        var launches = 0
        var notifications = 0
        var cancelCalls = 0

        override fun launch(continuation: PendingContinuation): Boolean {
            launches += 1
            events += "launch"
            return launchSucceeds
        }

        override fun notify(token: String): Boolean {
            notifications += 1
            events += "notify"
            return notifySucceeds
        }

        override fun cancelNotification() {
            cancelCalls += 1
            events += "cancel"
        }
    }
}
