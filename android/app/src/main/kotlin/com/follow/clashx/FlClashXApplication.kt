package com.follow.clashx

import android.app.Application
import android.content.Context
import android.os.Build
import com.follow.clashx.common.GlobalState as CommonGlobalState

class FlClashXApplication : Application() {
    companion object {
        private lateinit var instance: FlClashXApplication
        fun getAppContext(): Context = instance.applicationContext
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        CommonGlobalState.init(this)
        if (isMainProcess()) {
            GlobalState.install()
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
