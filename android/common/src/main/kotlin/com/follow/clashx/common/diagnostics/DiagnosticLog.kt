package com.follow.clashx.common.diagnostics

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

object DiagnosticLog {
    private const val DEFAULT_TAG = "FlClashM"
    private const val QUEUE_CAPACITY = 256
    private const val FLUSH_ACTION = "com.makriq.flclash.DIAGNOSTICS_FLUSH"
    private const val FLUSH_SENDER_PID = "senderPid"

    private val droppedEntries = AtomicInteger(0)
    private val handlingCrash = AtomicBoolean(false)
    private val initialized = AtomicBoolean(false)

    @Volatile private var store: DiagnosticFileStore? = null
    @Volatile private var processSource = "android-unknown"
    @Volatile private var previousCrashHandler: Thread.UncaughtExceptionHandler? = null

    private val writer = DiagnosticWriteQueue(
        capacity = QUEUE_CAPACITY,
        writeBatch = ::persistBatch,
        onDropped = droppedEntries::addAndGet,
    )

    fun initialize(application: Application) {
        if (!initialized.compareAndSet(false, true)) return
        val processName = currentProcessName(application)
        processSource = if (processName == application.packageName) {
            "android-main"
        } else {
            "android-remote"
        }
        val directory = File(application.filesDir, "diagnostics").apply { mkdirs() }
        store = DiagnosticFileStore(directory, processSource)
        installCrashHandler()
        ContextCompat.registerReceiver(
            application,
            FlushReceiver,
            IntentFilter(FLUSH_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        lifecycle(DEFAULT_TAG, "process created: $processSource")
    }

    fun requestOtherProcessesFlush(context: Context): Boolean = runCatching {
            context.sendBroadcast(
                Intent(FLUSH_ACTION)
                    .setPackage(context.packageName)
                    .putExtra(FLUSH_SENDER_PID, android.os.Process.myPid()),
            )
    }.isSuccess

    fun d(tag: String, message: String) = record(processSource, Log.DEBUG, tag, message)

    fun i(tag: String, message: String) = record(processSource, Log.INFO, tag, message)

    fun w(tag: String, message: String) = record(processSource, Log.WARN, tag, message)

    fun e(tag: String, message: String, error: Throwable? = null) {
        if (error == null) {
            record(processSource, Log.ERROR, tag, message)
        } else {
            recordThrowable(processSource, tag, message, error)
        }
    }

    fun lifecycle(tag: String, message: String) {
        record(processSource, Log.INFO, tag, message)
    }

    fun runtimeNode(type: String, line: String) {
        val source = when (type.lowercase()) {
            "naiveproxy", "byedpi", "olcrtc", "stormdns" -> "runtime-${type.lowercase()}"
            else -> "runtime-other"
        }
        record(source, Log.DEBUG, "FlClashM-runtime", line)
    }

    fun nativeCore(line: String) {
        val bounded = DiagnosticTextLimiter.truncateUtf8(
            line,
            MAX_DIAGNOSTIC_ENTRY_BYTES,
        )
        val normalized = bounded.lowercase()
        val bestEffort = normalized.startsWith("[mihomo][debug]") ||
            normalized.startsWith("[mihomo][info]")
        record(
            "mihomo-core",
            if (bestEffort) Log.DEBUG else Log.WARN,
            "FlClashM-native",
            bounded,
        )
    }

    fun coroutineFailure(error: Throwable) {
        recordThrowable(
            processSource,
            DEFAULT_TAG,
            "uncaught coroutine exception",
            error,
        )
    }

    fun flushBlocking(timeoutMillis: Long = 2_000L): Boolean {
        if (!initialized.get()) return true
        return runCatching { writer.flush(timeoutMillis) }.getOrDefault(false)
    }

    private fun record(
        source: String,
        priority: Int,
        tag: String,
        message: String,
    ) {
        val redacted = DiagnosticRedactor.redactBounded(message)
        Log.println(priority, tag, redacted)
        if (!initialized.get()) return
        writer.offer(format(source, priority, tag, redacted))
    }

    private fun recordThrowable(
        source: String,
        tag: String,
        message: String,
        error: Throwable,
        synchronous: Boolean = false,
    ) {
        val bounded = DiagnosticThrowableRenderer.render(
            message,
            error,
            MAX_DIAGNOSTIC_ENTRY_BYTES,
        )
        val redacted = DiagnosticRedactor.redactBounded(bounded)
        Log.e(tag, redacted)
        if (!initialized.get()) return
        val line = format(source, Log.ERROR, tag, redacted)
        if (synchronous) {
            try {
                store?.appendCrash(line)
            } catch (_: Throwable) {
                // Persistence must not replace the original uncaught exception.
            }
        } else {
            writer.offer(line)
        }
    }

    private fun persistBatch(lines: List<String>) {
        val output = ArrayList<String>(lines.size + 1)
        val dropped = droppedEntries.getAndSet(0)
        if (dropped > 0) {
            output.add(
                format(
                    processSource,
                    Log.WARN,
                    DEFAULT_TAG,
                    "diagnostic queue dropped $dropped newest entries",
                ),
            )
        }
        output.addAll(lines)
        store?.appendLines(output)
    }

    private fun format(source: String, priority: Int, tag: String, message: String): String {
        val level = when (priority) {
            Log.ERROR -> "ERROR"
            Log.WARN -> "WARN"
            Log.INFO -> "INFO"
            else -> "DEBUG"
        }
        return "[${Instant.now()}] [$level] [$source] [$tag] $message\n"
    }

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        previousCrashHandler = previous
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            if (handlingCrash.compareAndSet(false, true)) {
                runCatching {
                    recordThrowable(
                        processSource,
                        DEFAULT_TAG,
                        "uncaught thread exception on ${
                            DiagnosticTextLimiter.truncateUtf8(thread.name, 256)
                        }",
                        error,
                        synchronous = true,
                    )
                }
            }
            try {
                previousCrashHandler?.uncaughtException(thread, error)
            } finally {
                handlingCrash.set(false)
            }
        }
    }

    private fun currentProcessName(application: Application): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Application.getProcessName()
        } else {
            val pid = android.os.Process.myPid()
            val manager =
                application.getSystemService(Application.ACTIVITY_SERVICE)
                    as android.app.ActivityManager
            manager.runningAppProcesses
                ?.firstOrNull { it.pid == pid }
                ?.processName
                .orEmpty()
        }

    private object FlushReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getIntExtra(FLUSH_SENDER_PID, -1) == android.os.Process.myPid()) return
            val pendingResult = goAsync()
            try {
                Thread {
                    try {
                        flushBlocking()
                    } finally {
                        pendingResult.finish()
                    }
                }.apply {
                    isDaemon = true
                    name = "diagnostic-flush"
                }.start()
            } catch (_: Exception) {
                pendingResult.finish()
            }
        }
    }
}
