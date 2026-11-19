package com.follow.clashx.plugins

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import androidx.core.content.pm.PackageInfoCompat
import java.security.MessageDigest

/**
 * The identity Android reports for a package: which app it is, which build, and
 * which certificates signed it. The updater reads it before offering an install
 * so a wrong or unsigned file never reaches the installer.
 *
 * Signers are SHA-256 digests of the signing certificates, lowercase hex.
 */
internal object PackageIdentity {
    private val packageInfoFlags =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    /** Null when Android cannot describe this very app, which should not happen. */
    fun installed(context: Context): Map<String, Any>? =
        packageInfo(context, context.packageName)
            ?.let(::describe)

    /** Null when the file is not an installable package. */
    fun archive(
        context: Context,
        path: String,
    ): Map<String, Any>? =
        archiveInfo(context, path)
            ?.let(::describe)

    fun describe(info: PackageInfo): Map<String, Any> = mapOf(
        "packageName" to (info.packageName ?: ""),
        "versionCode" to PackageInfoCompat.getLongVersionCode(info),
        "signers" to signersOf(info).map { sha256Hex(it.toByteArray()) }.sorted(),
    )

    fun installedSigners(context: Context): Set<String> =
        packageInfo(context, context.packageName)?.let(::signerDigests).orEmpty()

    fun archiveSigners(
        context: Context,
        path: String,
    ): Set<String> = archiveInfo(context, path)?.let(::signerDigests).orEmpty()

    private fun signerDigests(info: PackageInfo): Set<String> =
        signersOf(info).map { sha256Hex(it.toByteArray()) }.toSet()

    private fun packageInfo(
        context: Context,
        packageName: String,
    ): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(packageInfoFlags.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(packageName, packageInfoFlags)
        }

    private fun archiveInfo(
        context: Context,
        path: String,
    ): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageArchiveInfo(
                path,
                PackageManager.PackageInfoFlags.of(packageInfoFlags.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageArchiveInfo(path, packageInfoFlags)
        }

    @Suppress("DEPRECATION")
    private fun signersOf(info: PackageInfo): List<Signature> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.toList().orEmpty()
        } else {
            info.signatures?.toList().orEmpty()
        }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
            "%02x".format(it)
        }
}

/**
 * The installer accepts an APK only when it carries the same certificates as
 * the running app. An unsigned running build has nothing to compare against,
 * so it accepts no self-update at all.
 */
internal fun selfUpdateSignersMatch(
    installed: Set<String>,
    candidate: Set<String>,
): Boolean = installed.isNotEmpty() && installed == candidate
