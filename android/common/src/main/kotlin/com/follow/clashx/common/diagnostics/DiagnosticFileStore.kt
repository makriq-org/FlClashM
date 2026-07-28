package com.follow.clashx.common.diagnostics

import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets

class DiagnosticFileStore(
    private val directory: File,
    source: String,
    private val maxFileBytes: Long = 256L * 1024L,
    private val maxFiles: Int = 3,
) {
    private val safeSource = source
        .lowercase()
        .replace(Regex("[^a-z0-9._-]"), "-")
        .trim('-')
        .ifEmpty { "unknown" }

    init {
        require(maxFileBytes > 0L)
        require(maxFiles > 0)
    }

    @Synchronized
    fun append(line: String) {
        directory.mkdirs()
        val bounded = line.take((maxFileBytes / 2L).coerceAtLeast(1L).toInt())
        val bytes = bounded.toByteArray(StandardCharsets.UTF_8)
        val current = file(0)
        if (current.exists() && current.length() + bytes.size > maxFileBytes) {
            rotate()
        }
        FileOutputStream(current, true).buffered().use { output ->
            output.write(bytes)
            output.flush()
        }
    }

    fun files(): List<File> =
        (0 until maxFiles).map(::file).filter(File::exists)

    private fun file(index: Int) = File(directory, "$safeSource.$index.log")

    private fun rotate() {
        file(maxFiles - 1).delete()
        for (index in maxFiles - 2 downTo 0) {
            val from = file(index)
            if (!from.exists()) continue
            val to = file(index + 1)
            to.delete()
            if (!from.renameTo(to)) {
                from.copyTo(to, overwrite = true)
                from.delete()
            }
        }
    }
}
