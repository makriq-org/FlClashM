package com.follow.clashx.service

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.RemoteException
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.chunkedForAidl
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.models.NotificationParams
import com.google.gson.Gson
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import java.util.UUID
import kotlin.coroutines.resume

/** IPC lifetime only. BackendHost and the VPN survive a Flutter binder death. */
class RemoteService : Service() {
    private val eventLock = Any()
    private var eventListener: IEventInterface? = null
    private var eventDeath: IBinder.DeathRecipient? = null

    private suspend fun dispatchChunked(
        data: String,
        send: (bytes: ByteArray, isSuccess: Boolean, ack: IAckInterface) -> Unit,
    ) {
        val bytes = data.toByteArray(Charsets.UTF_8)
        val chunks = bytes.chunkedForAidl().toList()
        for ((i, chunk) in chunks.withIndex()) {
            val isLast = i == chunks.lastIndex
            // true = acked, false = send threw (peer error), null = ACK timeout.
            val outcome = kotlinx.coroutines.withTimeoutOrNull(5_000L) {
                suspendCancellableCoroutine<Boolean> { cont ->
                    val ack = object : IAckInterface.Stub() {
                        override fun onAck() {
                            if (cont.isActive) cont.resume(true)
                        }
                    }
                    try {
                        send(chunk, isLast, ack)
                    } catch (e: RemoteException) {
                        GlobalState.log("dispatchChunked send failed on chunk ${i + 1}/${chunks.size}: ${e.message}")
                        if (cont.isActive) cont.resume(false)
                    }
                }
            }
            if (outcome != true) {
                if (outcome == null) {
                    GlobalState.log("dispatchChunked: ACK timeout on chunk ${i + 1}/${chunks.size}")
                }
                // Abort the stream (do NOT keep sending as if it were ACKed). If we had
                // not yet reached the terminal chunk, deliver a best-effort empty terminal
                // so the consumer flushes and the awaiting Dart completer fails fast
                // (empty/garbage -> default) instead of stranding until the 30s timeout.
                if (!isLast) {
                    runCatching {
                        send(ByteArray(0), true, object : IAckInterface.Stub() {
                            override fun onAck() {}
                        })
                    }
                }
                return
            }
        }
    }

    private val allowed = setOf(
        "backend", "getIsInit", "forceGc", "getProxies", "getTraffic", "getTotalTraffic",
        "asyncTestDelay", "getConnections", "getExternalProviders", "getExternalProvider",
        "getCountryCode", "getMemory", "getCoreVersion", "healthCheck", "healthProbe",
        "setUiActive", "startLog", "stopLog", "tunnelHTTPRequest", "cancelTunnelHTTPRequest",
        "getRuntimeSnapshot", "getAndroidVpnOptions", "getRunTime", "getCurrentProfileName",
    )

    private val stub = object : IRemoteInterface.Stub() {
        override fun invokeAction(data: String, callback: ICallbackInterface) {
            GlobalState.launch {
                val request = runCatching { JSONObject(data) }.getOrNull()
                if (request == null || request.optString("method") !in allowed) {
                    val failure = JSONObject().put("id", request?.optString("id") ?: "")
                        .put("method", request?.optString("method") ?: "")
                        .put("code", -1).put("data", "unsupported UI action")
                    dispatchChunked(failure.toString()) { bytes, last, ack -> callback.onResult(bytes, last, ack) }
                    return@launch
                }
                try {
                    BackendHost.initialize()
                    Core.invokeAction(data, object : InvokeInterface {
                        override fun onResult(result: String) {
                            GlobalState.launch { dispatchChunked(result) { bytes, last, ack -> callback.onResult(bytes, last, ack) } }
                        }
                    })
                } catch (error: Exception) {
                    val failure = JSONObject().put("id", request.optString("id"))
                        .put("method", request.optString("method"))
                        .put("code", -1).put("data", error.message ?: "backend initialization failed")
                    dispatchChunked(failure.toString()) { bytes, last, ack -> callback.onResult(bytes, last, ack) }
                }
            }
        }

        override fun setEventListener(event: IEventInterface?) = replaceListener(event)
        override fun registerStateCallback(callback: IStateCallback?) { callback?.let(StateHub::register) }
        override fun unregisterStateCallback(callback: IStateCallback?) { callback?.let(StateHub::unregister) }
        override fun getServiceState(): String = StateHub.snapshotJson()
        override fun getAndroidVpnOptions(): String = Core.getAndroidVpnOptions()
        override fun getAppliedAndroidVpnOptions(): String = State.readAppliedVpnOptions()?.let { Gson().toJson(it) } ?: ""
        override fun getCurrentProfileName(): String = Core.getCurrentProfileName()
        override fun getRunTime(): String = Core.getRunTime()
        override fun getTraffic(): String = Core.getTraffic()
        override fun getTotalTraffic(): String = Core.getTotalTraffic()
        override fun updateNotificationParams(params: NotificationParams) {
            // UI supplies only localized presentation strings. The profile title
            // is always read from the running Go engine, including headless use.
            State.notificationParamsFlow.value = params.copy(title = State.notificationParamsFlow.value.title)
        }
    }

    private fun replaceListener(event: IEventInterface?): Unit = synchronized(eventLock) {
        val previous = eventListener
        eventDeath?.let { runCatching { previous?.asBinder()?.unlinkToDeath(it, 0) } }
        eventListener = event
        eventDeath = null
        if (event == null) {
            BackendHost.onEvent = null
            Core.invokeAction("""{"id":"ui-detached","method":"setUiActive","data":false}""", object : InvokeInterface { override fun onResult(result: String) {} })
            return@synchronized
        }
        val death = IBinder.DeathRecipient {
            synchronized(eventLock) { if (eventListener === event) replaceListener(null) }
        }
        eventDeath = death
        try { event.asBinder().linkToDeath(death, 0) }
        catch (_: RemoteException) { replaceListener(null); return@synchronized }
        BackendHost.onEvent = { result ->
            GlobalState.launch {
                val id = UUID.randomUUID().toString()
                dispatchChunked(result) { bytes, last, ack -> event.onEvent(id, bytes, last, ack) }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        GlobalState.launch {
            runCatching { BackendHost.initialize() }
                .onFailure { GlobalState.log("backend initialization failed: ${it.message}") }
        }
    }
    override fun onBind(intent: Intent?): IBinder = stub
    override fun onDestroy() {
        replaceListener(null)
        // Do not close the process-owned backend when a UI unbinds this bridge.
        super.onDestroy()
    }
}
