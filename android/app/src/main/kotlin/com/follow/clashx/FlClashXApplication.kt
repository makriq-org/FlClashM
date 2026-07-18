package com.follow.clashx

import android.app.Application
import android.content.Context
import android.os.Build
import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.SavedParams

class FlClashXApplication : Application() {
    companion object {
        private lateinit var instance: FlClashXApplication
        fun getAppContext(): Context = instance.applicationContext
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        CommonGlobalState.init(this)
        // Before the main-process gate: :remote and headless starts must apply
        // the persisted flag too.
        CommonGlobalState.setCrashlytics(SavedParams.isCrashlyticsEnabled())
        if (isMainProcess()) {
            GlobalState.install()
        } else {
            // :remote hosts the Go core — capture its stderr so a core SIGABRT
            // (fatal error / panic) arrives with the Go reason, not just a
            // native stack.
            CommonGlobalState.captureNativeStderr()
        }
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
