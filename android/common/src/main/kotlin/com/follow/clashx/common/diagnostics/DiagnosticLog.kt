package com.follow.clashx.common.diagnostics

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.time.Instant
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

object DiagnosticLog {
    private const val DEFAULT_TAG = "FlClashM"
    private const val QUEUE_CAPACITY = 256
    private const val MAX_SOURCES_PER_PROCESS = 10
    private const val FLUSH_ACTION = "com.makriq.flclash.DIAGNOSTICS_FLUSH"

    private val stores = ConcurrentHashMap<String, DiagnosticFileStore>()
    private val droppedEntries = AtomicInteger(0)
    private val handlingCrash = AtomicBoolean(false)
    private val initialized = AtomicBoolean(false)
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(QUEUE_CAPACITY),
        { task -> Thread(task, "diagnostic-log-writer").apply { isDaemon = true } },
    )

    @Volatile private var directory: File? = null
    @Volatile private var processSource = "android-unknown"
    @Volatile private var previousCrashHandler: Thread.UncaughtExceptionHandler? = null

    fun initialize(application: Application) {
        if (!initialized.compareAndSet(false, true)) return
        directory = File(application.filesDir, "diagnostics").apply { mkdirs() }
        val processName = currentProcessName(application)
        processSource = if (processName == application.packageName) {
            "android-main"
        } else {
            "android-remote"
        }
        executor.prestartCoreThread()
        installCrashHandler()
        ContextCompat.registerReceiver(
            application,
            FlushReceiver,
            IntentFilter(FLUSH_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        application.registerActivityLifecycleCallbacks(ActivityLifecycleLogger)
        i(DEFAULT_TAG, "process created: $processSource")
    }

    fun requestAllProcessesFlush(context: Context) {
        context.sendBroadcast(
            Intent(FLUSH_ACTION).setPackage(context.packageName),
        )
    }

    fun d(tag: String, message: String) = record(processSource, Log.DEBUG, tag, message)

    fun i(tag: String, message: String) = record(processSource, Log.INFO, tag, message)

    fun w(tag: String, message: String) = record(processSource, Log.WARN, tag, message)

    fun e(tag: String, message: String, error: Throwable? = null) {
        if (error == null) {
            record(processSource, Log.ERROR, tag, message)
        } else {
            critical(processSource, tag, message, error)
        }
    }

    fun runtimeNode(type: String, line: String) {
        val source = when (type.lowercase()) {
            "naiveproxy", "byedpi", "olcrtc", "stormdns" -> "runtime-${type.lowercase()}"
            else -> "runtime-other"
        }
        record(source, Log.INFO, "FlClashM-runtime", line)
    }

    fun nativeCore(line: String) {
        record("mihomo-core", Log.INFO, "FlClashM-native", line)
    }

    fun coroutineFailure(error: Throwable) {
        critical(
            processSource,
            DEFAULT_TAG,
            "uncaught coroutine exception: ${error.message}",
            error,
        )
    }

    fun flushBlocking(timeoutMillis: Long = 2_000L): Boolean {
        if (!initialized.get()) return true
        val latch = CountDownLatch(1)
        enqueue(Runnable { latch.countDown() })
        return runCatching {
            latch.await(timeoutMillis, TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
    }

    private fun record(source: String, priority: Int, tag: String, message: String) {
        val redacted = DiagnosticRedactor.redact(message)
        Log.println(priority, tag, redacted)
        enqueue(
            Runnable {
                writeDroppedMarkerIfNeeded()
                store(source)?.append(format(priority, tag, redacted))
            },
        )
    }

    private fun critical(source: String, tag: String, message: String, error: Throwable) {
        val redacted = DiagnosticRedactor.redact("$message\n${error.stackTraceToString()}")
        Log.e(tag, redacted)
        runCatching {
            store("$source-critical")?.append(format(Log.ERROR, tag, redacted))
        }
    }

    private fun enqueue(task: Runnable) {
        if (!initialized.get()) return
        if (executor.queue.offer(task)) return
        executor.queue.poll()
        droppedEntries.incrementAndGet()
        executor.queue.offer(task)
    }

    private fun writeDroppedMarkerIfNeeded() {
        val dropped = droppedEntries.getAndSet(0)
        if (dropped <= 0) return
        store(processSource)?.append(
            format(
                Log.WARN,
                DEFAULT_TAG,
                "diagnostic queue dropped $dropped oldest entries",
            ),
        )
    }

    private fun store(source: String): DiagnosticFileStore? {
        val root = directory ?: return null
        if (!stores.containsKey(source) && stores.size >= MAX_SOURCES_PER_PROCESS) {
            return stores["android-overflow"]
                ?: stores.getOrPut("android-overflow") {
                    DiagnosticFileStore(root, "android-overflow")
                }
        }
        return stores.getOrPut(source) {
            DiagnosticFileStore(root, source)
        }
    }

    private fun format(priority: Int, tag: String, message: String): String {
        val level = when (priority) {
            Log.ERROR -> "ERROR"
            Log.WARN -> "WARN"
            Log.INFO -> "INFO"
            else -> "DEBUG"
        }
        return "[${Instant.now()}] [$level] [$tag] $message\n"
    }

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        previousCrashHandler = previous
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            if (handlingCrash.compareAndSet(false, true)) {
                runCatching {
                    critical(
                        processSource,
                        DEFAULT_TAG,
                        "uncaught thread exception on ${thread.name}: ${error.message}",
                        error,
                    )
                    flushBlocking(500L)
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

    private object ActivityLifecycleLogger : Application.ActivityLifecycleCallbacks {
        override fun onActivityCreated(activity: Activity, state: Bundle?) {
            d(DEFAULT_TAG, "${activity.javaClass.simpleName}: created")
        }

        override fun onActivityStarted(activity: Activity) {
            d(DEFAULT_TAG, "${activity.javaClass.simpleName}: started")
        }

        override fun onActivityResumed(activity: Activity) {
            i(DEFAULT_TAG, "${activity.javaClass.simpleName}: resumed")
        }

        override fun onActivityPaused(activity: Activity) {
            i(DEFAULT_TAG, "${activity.javaClass.simpleName}: paused")
        }

        override fun onActivityStopped(activity: Activity) {
            d(DEFAULT_TAG, "${activity.javaClass.simpleName}: stopped")
        }

        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit

        override fun onActivityDestroyed(activity: Activity) {
            d(DEFAULT_TAG, "${activity.javaClass.simpleName}: destroyed")
        }
    }

    private object FlushReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Thread {
                flushBlocking()
            }.apply {
                isDaemon = true
                name = "diagnostic-flush"
            }.start()
        }
    }
}
