package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.Process
import com.follow.clashx.common.GlobalState
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import org.json.JSONObject

/** Hosts mihomo's parser in :validator: parsing cannot alter the live engine. */
class BackendValidatorService : Service() {
    private val binder = object : IBackendValidator.Stub() {
        override fun getPid(): Int = Process.myPid()

        override fun validate(path: String, callback: ICallbackInterface) {
            val action = JSONObject()
                .put("id", "validate")
                .put("method", "backend.validate")
                .put("data", JSONObject().put("home", filesDir.absolutePath).put("path", path))
            Core.invokeAction(action.toString(), object : InvokeInterface {
                override fun onResult(result: String) {
                    runCatching { callback.onResult(result.toByteArray(Charsets.UTF_8), true, null) }
                }
            })
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
