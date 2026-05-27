package com.follow.clashx.common

import android.app.Application
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

object GlobalState {
    private const val TAG = "FlClashX"

    const val NOTIFICATION_CHANNEL = "FlClashX"
    const val NOTIFICATION_ID = 1

    lateinit var application: Application
        private set

    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun init(app: Application) {
        application = app
    }

    fun launch(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(block = block)

    fun log(message: String) {
        Log.d(TAG, message)
    }

    fun setCrashlytics(@Suppress("UNUSED_PARAMETER") enable: Boolean) {
    }
}
