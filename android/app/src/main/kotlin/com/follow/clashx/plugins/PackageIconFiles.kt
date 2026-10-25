package com.follow.clashx.plugins

import android.content.Context
import android.graphics.Bitmap
import androidx.core.graphics.drawable.toBitmap
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/** UI cache only. PackageManager is authoritative; no profile or VPN settings live here. */
internal object PackageIconFiles {
    private const val MAX_FILES = 256
    private const val TTL_MILLIS = 24 * 60 * 60 * 1000L

    @Synchronized
    fun path(context: Context, packageName: String): String {
        val manager = context.packageManager
        val info = runCatching { manager.getPackageInfo(packageName, 0) }.getOrNull()
        val key = iconCacheKey(if (info == null) "" else packageName, info?.lastUpdateTime ?: 0)
        val directory = File(context.cacheDir, "package-icons").apply { check(isDirectory || mkdirs()) }
        val target = File(directory, key)
        val now = System.currentTimeMillis()
        if (!target.isFile || target.length() == 0L || now - target.lastModified() > TTL_MILLIS) {
            val icon = if (info == null) manager.defaultActivityIcon else
                runCatching { manager.getApplicationIcon(packageName) }.getOrDefault(manager.defaultActivityIcon)
            val bitmap = icon.toBitmap(width = 128, height = 128)
            val temporary = File.createTempFile("icon-", ".tmp", directory)
            try {
                FileOutputStream(temporary).use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "Icon encoding failed" }
                }
                check(temporary.renameTo(target)) { "Icon cache publication failed" }
            } finally {
                temporary.delete()
                bitmap.recycle()
            }
        }
        target.setLastModified(now)
        directory.listFiles()?.filter { it != target }?.sortedByDescending { it.lastModified() }
            ?.drop(MAX_FILES - 1)?.forEach { it.delete() }
        return target.absolutePath
    }
}

/** Hash untrusted package names so cache paths cannot escape their directory. */
internal fun iconCacheKey(packageName: String, lastUpdateTime: Long): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(packageName.toByteArray(Charsets.UTF_8))
    return digest.joinToString("") { "%02x".format(it) } + "_$lastUpdateTime.png"
}
