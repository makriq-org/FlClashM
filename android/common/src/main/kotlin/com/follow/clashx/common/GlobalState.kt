package com.follow.clashx.common

import android.app.Application
import android.system.Os
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics
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
    private const val TAG = "FlClashX"

    const val NOTIFICATION_CHANNEL = "FlClashX"
    const val NOTIFICATION_ID = 1

    lateinit var application: Application
        private set

    @Volatile
    private var crashlyticsReady = false

    @Volatile
    private var stderrCaptured = false

    private val exceptionHandler = CoroutineExceptionHandler { _, e ->
        log("uncaught coroutine exception: ${e.message}")
    }

    val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + exceptionHandler)

    fun init(app: Application) {
        application = app
    }

    fun launch(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(block = block)

    fun log(message: String) {
        Log.d(TAG, message)
        // Breadcrumb attached to the next crash report. Only app-internal
        // technical messages flow through here; user data (configs, hosts,
        // notification titles) is deliberately kept out — see the "no sensitive
        // data" promise in settings.
        if (crashlyticsReady) {
            runCatching { FirebaseCrashlytics.getInstance().log(message) }
        }
    }

    /** Index a non-sensitive state value on subsequent crash reports. */
    fun crashKey(key: String, value: String) {
        if (!crashlyticsReady) return
        runCatching { FirebaseCrashlytics.getInstance().setCustomKey(key, value) }
    }

    fun setCrashlytics(enable: Boolean) {
        runCatching {
            // initializeApp returns null when the APK carries no Firebase config
            // (built without google-services.json) — degrade to a no-op then.
            FirebaseApp.initializeApp(application) ?: return
            FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = enable
            crashlyticsReady = enable
            log("crashlytics collection enabled=$enable")
        }.onFailure { log("setCrashlytics($enable) error: ${it.message}") }
    }

    /**
     * Redirect this process's stderr (fd 2) into a reader that mirrors every
     * line back to logcat and forwards it as a Crashlytics breadcrumb. The Go
     * core prints its fatal reason ("fatal error: concurrent map…", panics,
     * goroutine dumps) straight to stderr, bypassing every logger, so without
     * this a core SIGABRT arrives with a native stack but no cause. Call once in
     * the process that hosts the core (:remote). The captured text is Go-runtime
     * output, not user data. Mirroring keeps `adb logcat` working; the forward
     * only happens when Crashlytics is enabled.
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
                            Log.i("$TAG-native", line)
                            if (crashlyticsReady) {
                                runCatching {
                                    FirebaseCrashlytics.getInstance().log("native: $line")
                                }
                            }
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
