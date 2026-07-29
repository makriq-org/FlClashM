package com.follow.clashx.common.diagnostics

import java.io.Closeable
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.TimeUnit

const val MAX_DIAGNOSTIC_ENTRY_BYTES = 16 * 1024

internal object DiagnosticTextLimiter {
    const val TRUNCATED_SUFFIX = "…<truncated>"

    fun truncateUtf8(
        value: String,
        maxBytes: Int,
        suffix: String = TRUNCATED_SUFFIX,
    ): String {
        require(maxBytes >= 0) { "UTF-8 limit must not be negative" }
        if (value.isEmpty() || maxBytes == 0) return if (value.isEmpty()) value else ""

        val suffixBytes = utf8Length(suffix)
        val usableSuffix = if (suffixBytes <= maxBytes) suffix else ""
        val contentLimit = maxBytes - if (usableSuffix.isEmpty()) 0 else suffixBytes
        var index = 0
        var bytes = 0
        var contentEnd = 0

        while (index < value.length) {
            val codePoint = Character.codePointAt(value, index)
            val codePointBytes = utf8Length(codePoint)
            if (bytes + codePointBytes > maxBytes) break
            bytes += codePointBytes
            index += Character.charCount(codePoint)
            if (bytes <= contentLimit) contentEnd = index
        }
        if (index == value.length) return value
        if (usableSuffix.isEmpty()) return value.substring(0, index)
        return value.substring(0, contentEnd) + usableSuffix
    }

    internal fun utf8Length(value: String): Int {
        var result = 0
        var index = 0
        while (index < value.length) {
            val codePoint = Character.codePointAt(value, index)
            result += utf8Length(codePoint)
            index += Character.charCount(codePoint)
        }
        return result
    }

    private fun utf8Length(codePoint: Int): Int = when {
        codePoint <= 0x7f -> 1
        codePoint <= 0x7ff -> 2
        codePoint <= 0xffff -> 3
        else -> 4
    }
}

internal object DiagnosticThrowableRenderer {
    private const val MAX_CAUSES = 8
    private const val MAX_FRAMES = 64
    private const val TRUNCATED = "…<truncated>"

    fun render(context: String, error: Throwable, maxBytes: Int = MAX_DIAGNOSTIC_ENTRY_BYTES): String {
        require(maxBytes > DiagnosticTextLimiter.utf8Length(TRUNCATED)) {
            "Throwable limit must leave room for the truncation marker"
        }
        val output = StringBuilder(minOf(maxBytes, 1024))
        var bytes = 0
        var truncated = false
        fun append(value: String): Boolean {
            if (value.isEmpty() || truncated) return false
            val bounded = DiagnosticTextLimiter.truncateUtf8(value, maxBytes - bytes, suffix = "")
            output.append(bounded)
            bytes += DiagnosticTextLimiter.utf8Length(bounded)
            if (bounded.length != value.length) truncated = true
            return !truncated
        }

        append(context)
        append("\n")
        val visited = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        var current: Throwable? = error
        var depth = 0
        while (current != null && depth < MAX_CAUSES && !truncated) {
            val throwable = current
            if (!visited.add(throwable)) {
                append("<circular throwable>\n")
                break
            }
            if (depth > 0) append("Caused by: ")
            append(throwable.javaClass.name)
            runCatching { throwable.message }.getOrNull()?.takeIf(String::isNotEmpty)?.let {
                append(": ")
                append(it)
            }
            append("\n")
            val frames = runCatching { throwable.stackTrace }.getOrDefault(emptyArray())
            for (index in 0 until minOf(frames.size, MAX_FRAMES)) {
                append("\tat ${frames[index]}\n")
                if (truncated) break
            }
            if (frames.size > MAX_FRAMES && !truncated) append("\t… frames omitted\n")
            current = runCatching { throwable.cause }.getOrNull()
            depth++
        }
        if (truncated) {
            val content = DiagnosticTextLimiter.truncateUtf8(
                output.toString(),
                maxBytes - DiagnosticTextLimiter.utf8Length(TRUNCATED),
                suffix = "",
            )
            return content + TRUNCATED
        }
        return output.toString()
    }
}

class BoundedUtf8LineReader(
    private val input: InputStream,
    private val maxLineBytes: Int = MAX_DIAGNOSTIC_ENTRY_BYTES,
) : Closeable {
    private val truncatedSuffix = "…<truncated>"
    private val suffixBytes = truncatedSuffix.toByteArray(StandardCharsets.UTF_8).size

    init {
        require(maxLineBytes > suffixBytes) {
            "Line limit must leave room for the truncation marker"
        }
    }

    fun forEachLine(action: (String) -> Unit) {
        val chunk = ByteArray(DEFAULT_BUFFER_SIZE)
        val line = ByteArray(maxLineBytes)
        var length = 0
        var truncated = false
        var hasInput = false
        var skipFollowingLineFeed = false

        fun emit() {
            val decoded = if (truncated) {
                val contentLimit = maxLineBytes - suffixBytes
                val prefixLength = completeUtf8PrefixLength(
                    line,
                    minOf(length, contentLimit),
                )
                val prefix = String(
                    line,
                    0,
                    prefixLength,
                    StandardCharsets.UTF_8,
                )
                DiagnosticTextLimiter.truncateUtf8(
                    prefix,
                    contentLimit,
                    suffix = "",
                ) + truncatedSuffix
            } else {
                String(line, 0, length, StandardCharsets.UTF_8)
            }
            action(decoded)
            length = 0
            truncated = false
            hasInput = false
        }

        while (true) {
            val read = input.read(chunk)
            if (read < 0) break
            for (index in 0 until read) {
                val byte = chunk[index]
                if (byte == '\n'.code.toByte()) {
                    if (skipFollowingLineFeed) {
                        skipFollowingLineFeed = false
                        continue
                    }
                    emit()
                    continue
                }
                if (byte == '\r'.code.toByte()) {
                    emit()
                    skipFollowingLineFeed = true
                    continue
                }
                skipFollowingLineFeed = false
                hasInput = true
                if (length < line.size) {
                    line[length++] = byte
                } else {
                    truncated = true
                }
            }
        }
        if (hasInput || length > 0 || truncated) emit()
    }

    override fun close() {
        input.close()
    }

    private fun completeUtf8PrefixLength(bytes: ByteArray, length: Int): Int {
        if (length <= 0) return 0
        var leadIndex = length - 1
        while (
            leadIndex >= 0 &&
            bytes[leadIndex].toInt() and 0xc0 == 0x80
        ) {
            leadIndex--
        }
        if (leadIndex < 0) return 0
        val lead = bytes[leadIndex].toInt() and 0xff
        val sequenceLength = when {
            lead and 0x80 == 0 -> 1
            lead and 0xe0 == 0xc0 -> 2
            lead and 0xf0 == 0xe0 -> 3
            lead and 0xf8 == 0xf0 -> 4
            else -> 1
        }
        return if (length - leadIndex < sequenceLength) leadIndex else length
    }
}

internal class DiagnosticWriteQueue(
    private val capacity: Int,
    private val writeBatch: (List<String>) -> Unit,
    private val onDropped: (Int) -> Unit = {},
) {
    private sealed interface Command {
        data class Line(val value: String) : Command
        data class Flush(val result: CompletableFuture<Boolean>) : Command
    }

    private val queue = ArrayBlockingQueue<Command>(capacity)
    private val worker = Thread(::runLoop, "diagnostic-log-writer").apply { isDaemon = true }

    init {
        require(capacity > 0) { "Diagnostic queue must retain entries" }
        worker.start()
    }

    fun offer(line: String) {
        if (!queue.offer(Command.Line(line))) notifyDropped(1)
    }

    fun flush(timeoutMillis: Long): Boolean {
        require(timeoutMillis >= 0L)
        val result = CompletableFuture<Boolean>()
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        return try {
            if (!queue.offer(Command.Flush(result), timeoutMillis, TimeUnit.MILLISECONDS)) return false
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0L) return result.isDone && result.getNow(false)
            result.get(remaining, TimeUnit.NANOSECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun notifyDropped(count: Int) {
        runCatching { onDropped(count) }
    }

    private fun runLoop() {
        var failed = false
        while (true) {
            when (val command = queue.take()) {
                is Command.Flush -> {
                    command.result.complete(!failed)
                    failed = false
                }
                is Command.Line -> {
                    val lines = ArrayList<String>(MAX_BATCH_ENTRIES)
                    lines.add(command.value)
                    while (lines.size < MAX_BATCH_ENTRIES) {
                        val next = queue.peek() as? Command.Line ?: break
                        queue.poll()
                        lines.add(next.value)
                    }
                    try {
                        writeBatch(lines)
                    } catch (_: Throwable) {
                        failed = true
                        // Diagnostic persistence must never reach the process crash handler.
                    }
                }
            }
        }
    }

    private companion object {
        const val MAX_BATCH_ENTRIES = 64
    }
}
