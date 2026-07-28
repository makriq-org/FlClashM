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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

object DiagnosticLog {
    private const val DEFAULT_TAG = "FlClashM"
    private const val QUEUE_CAPACITY = 256
    private const val PROTECTED_QUEUE_RESERVE = 64
    private const val MAX_SOURCES_PER_PROCESS = 10
    private const val FLUSH_ACTION = "com.makriq.flclash.DIAGNOSTICS_FLUSH"

    private val stores = ConcurrentHashMap<String, DiagnosticFileStore>()
    private val droppedEntries = AtomicInteger(0)
    private val persistenceHealth = DiagnosticPersistenceHealth { error ->
        Log.e(
            DEFAULT_TAG,
            "diagnostic persistence failed: ${error.javaClass.simpleName}",
        )
    }
    private val handlingCrash = AtomicBoolean(false)
    private val initialized = AtomicBoolean(false)
    private val executor = DiagnosticTaskQueue(
        capacity = QUEUE_CAPACITY,
        protectedReserve = PROTECTED_QUEUE_RESERVE,
        onDropped = droppedEntries::addAndGet,
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
        installCrashHandler()
        ContextCompat.registerReceiver(
            application,
            FlushReceiver,
            IntentFilter(FLUSH_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        application.registerActivityLifecycleCallbacks(ActivityLifecycleLogger)
        lifecycle(DEFAULT_TAG, "process created: $processSource")
    }

    fun requestAllProcessesFlush(
        context: Context,
        timeoutMillis: Long = 5_000L,
    ): Boolean {
        val acknowledged = CountDownLatch(1)
        val flushComplete = AtomicBoolean(false)
        val completion = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                flushComplete.set(resultCode == Activity.RESULT_OK)
                acknowledged.countDown()
            }
        }
        val sent = runCatching {
            context.sendOrderedBroadcast(
                Intent(FLUSH_ACTION).setPackage(context.packageName),
                null,
                completion,
                null,
                Activity.RESULT_OK,
                null,
                null,
            )
            true
        }.getOrDefault(false)
        if (!sent) return false
        val completed = runCatching {
            acknowledged.await(timeoutMillis, TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
        return completed && flushComplete.get()
    }

    fun d(tag: String, message: String) = record(processSource, Log.DEBUG, tag, message)

    fun i(tag: String, message: String) = record(processSource, Log.INFO, tag, message)

    fun w(tag: String, message: String) = record(
        processSource,
        Log.WARN,
        tag,
        message,
        protected = true,
        synchronous = true,
    )

    fun e(tag: String, message: String, error: Throwable? = null) {
        if (error == null) {
            record(
                processSource,
                Log.ERROR,
                tag,
                message,
                protected = true,
                synchronous = true,
            )
        } else {
            critical(processSource, tag, message, error)
        }
    }

    fun lifecycle(tag: String, message: String) {
        record(processSource, Log.INFO, tag, message, protected = true)
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
            protected = !bestEffort,
            synchronous = !bestEffort,
        )
    }

    fun coroutineFailure(error: Throwable) {
        critical(
            processSource,
            DEFAULT_TAG,
            "uncaught coroutine exception",
            error,
        )
    }

    fun flushBlocking(timeoutMillis: Long = 2_000L): Boolean {
        if (!initialized.get()) return true
        val startedAt = System.nanoTime()
        val drained = runCatching {
            executor.flush(timeoutMillis)
        }.getOrDefault(false)
        if (!drained) return false
        val markerId = executor.offerControl(
            Runnable {
                safePersistence { writeDroppedMarkerIfNeeded() }
            },
        )
            ?: return false
        val elapsed = System.nanoTime() - startedAt
        val remaining = TimeUnit.MILLISECONDS.toNanos(timeoutMillis) - elapsed
        if (remaining <= 0L) return false
        val markerCompleted = runCatching {
            executor.awaitCompletion(markerId, remaining)
        }.getOrDefault(false)
        return markerCompleted && persistenceHealth.isHealthy
    }

    private fun record(
        source: String,
        priority: Int,
        tag: String,
        message: String,
        protected: Boolean = false,
        synchronous: Boolean = false,
    ) {
        val redacted = DiagnosticRedactor.redactBounded(message)
        Log.println(priority, tag, redacted)
        if (!initialized.get()) return
        val line = format(priority, tag, redacted)
        if (synchronous) {
            executor.runSynchronously(Runnable { persist(source, line) })
        } else {
            enqueue(Runnable { persist(source, line) }, protected)
        }
    }

    private fun critical(source: String, tag: String, message: String, error: Throwable) {
        val bounded = DiagnosticThrowableRenderer.render(
            message,
            error,
            MAX_DIAGNOSTIC_ENTRY_BYTES,
        )
        val redacted = DiagnosticRedactor.redactBounded(bounded)
        Log.e(tag, redacted)
        val persistence = Runnable {
            safePersistence {
                store("$source-critical")?.append(format(Log.ERROR, tag, redacted))
            }
        }
        if (!initialized.get() || !executor.runSynchronously(persistence)) {
            persistence.run()
        }
    }

    private fun enqueue(task: Runnable, protected: Boolean) {
        if (!initialized.get()) return
        executor.offer(task, protected)
    }

    private fun persist(source: String, line: String) {
        safePersistence { writeDroppedMarkerIfNeeded() }
        safePersistence { store(source)?.append(line) }
    }

    private fun safePersistence(block: () -> Unit) {
        persistenceHealth.run(block)
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
                        "uncaught thread exception on ${
                            DiagnosticTextLimiter.truncateUtf8(
                                thread.name,
                                256,
                            )
                        }",
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
            lifecycle(DEFAULT_TAG, "${activity.javaClass.simpleName}: created")
        }

        override fun onActivityStarted(activity: Activity) {
            lifecycle(DEFAULT_TAG, "${activity.javaClass.simpleName}: started")
        }

        override fun onActivityResumed(activity: Activity) {
            lifecycle(DEFAULT_TAG, "${activity.javaClass.simpleName}: resumed")
        }

        override fun onActivityPaused(activity: Activity) {
            lifecycle(DEFAULT_TAG, "${activity.javaClass.simpleName}: paused")
        }

        override fun onActivityStopped(activity: Activity) {
            lifecycle(DEFAULT_TAG, "${activity.javaClass.simpleName}: stopped")
        }

        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit

        override fun onActivityDestroyed(activity: Activity) {
            lifecycle(DEFAULT_TAG, "${activity.javaClass.simpleName}: destroyed")
        }
    }

    private object FlushReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val pendingResult = goAsync()
            try {
                Thread {
                    try {
                        if (!flushBlocking()) {
                            pendingResult.setResultCode(Activity.RESULT_CANCELED)
                        }
                    } finally {
                        pendingResult.finish()
                    }
                }.apply {
                    isDaemon = true
                    name = "diagnostic-flush"
                }.start()
            } catch (_: Exception) {
                pendingResult.setResultCode(Activity.RESULT_CANCELED)
                pendingResult.finish()
            }
        }
    }
}
