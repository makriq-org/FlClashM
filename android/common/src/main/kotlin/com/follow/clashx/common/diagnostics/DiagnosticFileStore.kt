package com.follow.clashx.common.diagnostics

import java.io.BufferedOutputStream
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
    fun appendLines(lines: List<String>) {
        if (lines.isEmpty()) return
        directory.mkdirs()
        var output: BufferedOutputStream? = null
        var length = file(0).takeIf(File::exists)?.length() ?: 0L
        try {
            for (line in lines) {
                val bounded = DiagnosticTextLimiter.truncateUtf8(
                    line,
                    maxFileBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                    suffix = "",
                )
                val bytes = bounded.toByteArray(StandardCharsets.UTF_8)
                if (length > 0L && length + bytes.size > maxFileBytes) {
                    output?.flush()
                    output?.close()
                    output = null
                    rotate()
                    length = 0L
                }
                if (output == null) {
                    output = BufferedOutputStream(FileOutputStream(file(0), true))
                }
                output.write(bytes)
                length += bytes.size
            }
            output?.flush()
        } finally {
            output?.close()
        }
    }

    fun appendCrash(line: String) = appendLines(listOf(line))

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
