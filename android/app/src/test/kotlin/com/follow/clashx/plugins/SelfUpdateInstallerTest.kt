package com.follow.clashx.plugins

import android.content.pm.PackageInstaller
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SelfUpdateInstallerTest {
    @Test
    fun `session is used only on Android 12 plus with installer access`() {
        assertFalse(shouldUsePackageInstallerSession(30, true))
        assertFalse(shouldUsePackageInstallerSession(31, false))
        assertTrue(shouldUsePackageInstallerSession(31, true))
    }

    @Test
    fun `success and cancellation need no follow-up`() {
        assertEquals(
            InstallStatusAction.NONE,
            installStatusAction(PackageInstaller.STATUS_SUCCESS, false),
        )
        assertEquals(
            InstallStatusAction.NONE,
            installStatusAction(PackageInstaller.STATUS_FAILURE_ABORTED, true),
        )
    }

    @Test
    fun `pending status uses the system intent or interactive fallback`() {
        assertEquals(
            InstallStatusAction.SYSTEM_CONFIRMATION,
            installStatusAction(PackageInstaller.STATUS_PENDING_USER_ACTION, true),
        )
        assertEquals(
            InstallStatusAction.INTERACTIVE_FALLBACK,
            installStatusAction(PackageInstaller.STATUS_PENDING_USER_ACTION, false),
        )
    }

    @Test
    fun `terminal failure does not relaunch the installer`() {
        assertEquals(
            InstallStatusAction.NONE,
            installStatusAction(PackageInstaller.STATUS_FAILURE_BLOCKED, true),
        )
    }

    @Test
    fun `committed self session provides single flight`() {
        val sessions = listOf(
            SessionSnapshot(10, "com.makriq.flclash", false),
            SessionSnapshot(11, "other.package", true),
            SessionSnapshot(12, "com.makriq.flclash", true),
        )

        assertEquals(
            12,
            committedSelfUpdateSessionId(sessions, "com.makriq.flclash"),
        )
        assertNull(
            committedSelfUpdateSessionId(sessions, "missing.package"),
        )
    }
}
