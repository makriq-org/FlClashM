package com.follow.clashx

import android.app.Application
import android.content.Context
import android.os.Build
import com.follow.clashx.common.diagnostics.DiagnosticLog
import com.follow.clashx.common.GlobalState as CommonGlobalState

class FlClashApplication : Application() {
    companion object {
        private lateinit var instance: FlClashApplication
        fun getAppContext(): Context = instance.applicationContext
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        DiagnosticLog.initialize(this)
        CommonGlobalState.init(this)
        if (isMainProcess()) {
            GlobalState.install()
        } else {
            // :remote hosts the Go core. Mirror stderr to local logcat so fatal
            // reasons remain available through adb without remote telemetry.
            CommonGlobalState.captureNativeStderr()
        }
    }

    override fun onLowMemory() {
        DiagnosticLog.w("FlClashApplication", "application received onLowMemory")
        super.onLowMemory()
    }

    override fun onTrimMemory(level: Int) {
        DiagnosticLog.i("FlClashApplication", "application trim-memory level=$level")
        super.onTrimMemory(level)
    }

    override fun onTerminate() {
        DiagnosticLog.lifecycle("FlClashApplication", "application terminating")
        DiagnosticLog.flushBlocking()
        super.onTerminate()
    }

    private fun isMainProcess(): Boolean {
        val processName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            getProcessName()
        } else {
            val pid = android.os.Process.myPid()
            val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            am.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName
        }
        return processName == packageName
    }
}
