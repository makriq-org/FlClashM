package com.follow.clashx.common.diagnostics

import java.io.Closeable
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

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
    private const val MAX_THROWABLES = 8
    private const val MAX_FRAMES_PER_THROWABLE = 64

    fun render(
        context: String,
        error: Throwable,
        maxBytes: Int = MAX_DIAGNOSTIC_ENTRY_BYTES,
    ): String {
        val output = BoundedUtf8Appender(maxBytes)
        output.append(context)
        output.append("\n")
        val visited = Collections.newSetFromMap(
            IdentityHashMap<Throwable, Boolean>(),
        )
        renderThrowable(
            output = output,
            error = error,
            caption = "",
            visited = visited,
            depth = 0,
        )
        return output.value()
    }

    private fun renderThrowable(
        output: BoundedUtf8Appender,
        error: Throwable,
        caption: String,
        visited: MutableSet<Throwable>,
        depth: Int,
    ) {
        if (output.isTruncated || depth >= MAX_THROWABLES) return
        if (!visited.add(error)) {
            output.append("$caption<circular throwable>\n")
            return
        }
        output.append(caption)
        output.append(error.javaClass.name)
        val message = runCatching { error.message }.getOrNull()
        if (!message.isNullOrEmpty()) {
            output.append(": ")
            output.append(message)
        }
        output.append("\n")

        val frames = runCatching { error.stackTrace }.getOrDefault(emptyArray())
        var frameCount = 0
        for (frame in frames) {
            if (frameCount >= MAX_FRAMES_PER_THROWABLE || output.isTruncated) break
            output.append("\tat ")
            output.append(frame.toString())
            output.append("\n")
            frameCount++
        }
        if (frames.size > frameCount && !output.isTruncated) {
            output.append("\t… ${frames.size - frameCount} frames omitted\n")
        }

        val suppressed = runCatching { error.suppressed }.getOrDefault(emptyArray())
        for (suppressedError in suppressed) {
            if (output.isTruncated || visited.size >= MAX_THROWABLES) break
            renderThrowable(
                output = output,
                error = suppressedError,
                caption = "Suppressed: ",
                visited = visited,
                depth = depth + 1,
            )
        }
        val cause = runCatching { error.cause }.getOrNull()
        if (
            cause != null &&
            !output.isTruncated &&
            visited.size < MAX_THROWABLES
        ) {
            renderThrowable(
                output = output,
                error = cause,
                caption = "Caused by: ",
                visited = visited,
                depth = depth + 1,
            )
        }
    }

    private class BoundedUtf8Appender(
        private val maxBytes: Int,
    ) {
        private val suffix = "…<truncated>"
        private val suffixBytes = DiagnosticTextLimiter.utf8Length(suffix)
        private val builder = StringBuilder(minOf(maxBytes, 1024))
        private var bytes = 0
        var isTruncated = false
            private set

        init {
            require(maxBytes > suffixBytes) {
                "Throwable limit must leave room for the truncation marker"
            }
        }

        fun append(value: String) {
            if (value.isEmpty() || isTruncated) return
            val remaining = maxBytes - bytes
            val bounded = DiagnosticTextLimiter.truncateUtf8(
                value,
                remaining,
                suffix = "",
            )
            builder.append(bounded)
            bytes += DiagnosticTextLimiter.utf8Length(bounded)
            if (bounded.length != value.length) markTruncated()
        }

        fun value(): String = builder.toString()

        private fun markTruncated() {
            val content = DiagnosticTextLimiter.truncateUtf8(
                builder.toString(),
                maxBytes - suffixBytes,
                suffix = "",
            )
            builder.clear()
            builder.append(content)
            builder.append(suffix)
            bytes = maxBytes
            isTruncated = true
        }
    }
}

internal class DiagnosticPersistenceHealth(
    private val onFailure: (Exception) -> Unit = {},
) {
    private val failed = AtomicBoolean(false)

    val isHealthy: Boolean
        get() = !failed.get()

    fun run(action: () -> Unit): Boolean {
        return try {
            action()
            true
        } catch (error: Exception) {
            failed.set(true)
            runCatching { onFailure(error) }
            false
        }
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
    threadFactory: (Runnable) -> Thread = { task ->
        Thread(task, "diagnostic-log-writer").apply { isDaemon = true }
    },
    private val onDropped: (Int) -> Unit = {},
) {
    private data class Pending(
        val line: String? = null,
        val flush: CountDownLatch? = null,
    )

    private val monitor = Object()
    private val pending = ArrayDeque<Pending>()
    private var pendingLines = 0
    private var running = true
    private val worker = threadFactory(Runnable(::runLoop))

    init {
        require(capacity > 0) { "Diagnostic queue must retain entries" }
        worker.start()
    }

    fun offer(line: String) {
        synchronized(monitor) {
            if (!running) {
                notifyDropped(1)
                return
            }
            if (pendingLines >= capacity) {
                val iterator = pending.iterator()
                while (iterator.hasNext()) {
                    if (iterator.next().line != null) {
                        iterator.remove()
                        pendingLines--
                        notifyDropped(1)
                        break
                    }
                }
            }
            pending.addLast(Pending(line = line))
            pendingLines++
            monitor.notifyAll()
        }
    }

    fun flush(timeoutMillis: Long): Boolean {
        require(timeoutMillis >= 0L)
        val completed = CountDownLatch(1)
        synchronized(monitor) {
            if (!running) return false
            pending.addLast(Pending(flush = completed))
            monitor.notifyAll()
        }
        return try {
            completed.await(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    fun shutdownNow() {
        synchronized(monitor) {
            running = false
            if (pendingLines > 0) notifyDropped(pendingLines)
            pending.forEach { it.flush?.countDown() }
            pending.clear()
            pendingLines = 0
            monitor.notifyAll()
        }
    }

    private fun notifyDropped(count: Int) {
        runCatching { onDropped(count) }
    }

    private fun runLoop() {
        while (true) {
            val task = synchronized(monitor) {
                while (running && pending.isEmpty()) {
                    monitor.wait()
                }
                if (!running && pending.isEmpty()) return
                pending.removeFirst().also {
                    if (it.line != null) pendingLines--
                }
            }

            if (task.flush != null) {
                task.flush.countDown()
                continue
            }

            val lines = ArrayList<String>(MAX_BATCH_ENTRIES)
            task.line?.let(lines::add)
            synchronized(monitor) {
                while (lines.size < MAX_BATCH_ENTRIES) {
                    val next = pending.peekFirst() ?: break
                    val line = next.line ?: break
                    pending.removeFirst()
                    pendingLines--
                    lines.add(line)
                }
            }
            try {
                writeBatch(lines)
            } catch (_: Throwable) {
                // Diagnostic persistence must never reach the process crash handler.
            }
        }
    }

    private companion object {
        const val MAX_BATCH_ENTRIES = 64
    }
}
