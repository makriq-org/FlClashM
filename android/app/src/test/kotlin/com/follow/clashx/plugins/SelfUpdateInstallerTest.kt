package com.follow.clashx.plugins

import android.content.pm.PackageInstaller
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
    fun `pending user action launches the supplied system intent`() {
        assertEquals(
            InstallStatusAction.LAUNCH_SYSTEM_INTENT,
            installStatusAction(
                status = PackageInstaller.STATUS_PENDING_USER_ACTION,
                hasSystemIntent = true,
            ),
        )
    }

    @Test
    fun `pending user action without intent uses interactive fallback`() {
        assertEquals(
            InstallStatusAction.LAUNCH_INTERACTIVE_FALLBACK,
            installStatusAction(
                status = PackageInstaller.STATUS_PENDING_USER_ACTION,
                hasSystemIntent = false,
            ),
        )
    }

    @Test
    fun `user cancellation does not reopen the installer`() {
        assertEquals(
            InstallStatusAction.NONE,
            installStatusAction(
                status = PackageInstaller.STATUS_FAILURE_ABORTED,
                hasSystemIntent = false,
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
                InstallStatusAction.LAUNCH_INTERACTIVE_FALLBACK,
                installStatusAction(
                    status = status,
                    hasSystemIntent = false,
                ),
            )
        }
    }
}
