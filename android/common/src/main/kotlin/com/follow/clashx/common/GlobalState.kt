package com.follow.clashx.common

import android.app.Application
import android.system.Os
import com.follow.clashx.common.diagnostics.DiagnosticLog
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.FileInputStream
import java.io.InputStreamReader

object GlobalState {
    private const val TAG = "FlClashM"

    const val NOTIFICATION_CHANNEL = "FlClashM"
    const val NOTIFICATION_ID = 1

    lateinit var application: Application
        private set

    @Volatile
    private var stderrCaptured = false

    private val exceptionHandler = CoroutineExceptionHandler { _, e ->
        DiagnosticLog.coroutineFailure(e)
    }

    val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + exceptionHandler)

    fun init(app: Application) {
        application = app
    }

    fun launch(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(block = block)

    fun log(message: String) {
        DiagnosticLog.d(TAG, message)
    }

    /**
     * Redirect this process's stderr (fd 2) into local logcat. The Go core prints
     * fatal reasons and panic details straight to stderr, bypassing other loggers.
     * Call once in the process that hosts the core (:remote).
     */
    fun captureNativeStderr() {
        if (stderrCaptured) return
        stderrCaptured = true
        runCatching {
            val pipe = Os.pipe()
            val readFd = pipe[0]
            val writeFd = pipe[1]
            Os.dup2(writeFd, 2)
            Thread {
                runCatching {
                    BufferedReader(InputStreamReader(FileInputStream(readFd))).useLines { lines ->
                        lines.forEach { line ->
                            DiagnosticLog.nativeCore(line)
                        }
                    }
                }
            }.apply {
                isDaemon = true
                name = "native-stderr-capture"
            }.start()
        }.onFailure { log("captureNativeStderr error: ${it.message}") }
    }
}
