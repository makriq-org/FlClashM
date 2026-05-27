package com.follow.clashx.service

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.RemoteException
import android.os.SystemClock
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.ServiceDelegate
import com.follow.clashx.common.chunkedForAidl
import com.follow.clashx.common.intent
import com.follow.clashx.core.Core
import com.follow.clashx.core.InvokeInterface
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

class RemoteService : Service() {

    private val eventListener = AtomicReference<com.follow.clashx.service.IEventInterface?>(null)

    private suspend fun dispatchChunked(
        data: String,
        send: (bytes: ByteArray, isSuccess: Boolean, ack: IAckInterface) -> Unit,
    ) {
        val bytes = data.toByteArray(Charsets.UTF_8)
        val chunks = bytes.chunkedForAidl().toList()
        for ((i, chunk) in chunks.withIndex()) {
            val isLast = i == chunks.lastIndex
            val acked = kotlinx.coroutines.withTimeoutOrNull(5_000L) {
                suspendCancellableCoroutine<Unit> { cont ->
                    val ack = object : IAckInterface.Stub() {
                        override fun onAck() {
                            cont.resume(Unit)
                        }
                    }
                    try {
                        send(chunk, isLast, ack)
                    } catch (e: RemoteException) {
                        GlobalState.log("dispatchChunked failed: ${e.message}")
                        cont.resume(Unit)
                    }
                }
            }
            if (acked == null) {
                GlobalState.log("dispatchChunked: ACK timeout on chunk ${i + 1}/${chunks.size}")
                return
            }
        }
    }

    private val stub = object : IRemoteInterface.Stub() {

        override fun invokeAction(data: String, callback: ICallbackInterface) {
            GlobalState.launch {
                Core.invokeAction(data, object : InvokeInterface {
                    override fun onResult(result: String) {
                        GlobalState.launch {
                            dispatchChunked(result) { bytes, isSuccess, ack ->
                                callback.onResult(bytes, isSuccess, ack)
                            }
                        }
                    }
                })
            }
        }

        override fun quickStart(
            initParamsString: String,
            paramsString: String,
            stateParamsString: String,
            callback: ICallbackInterface,
            onStarted: IVoidInterface,
        ) {
            GlobalState.launch {
                com.follow.clashx.common.SavedParams.saveQuickStartParams(
                    initParamsString, paramsString, stateParamsString,
                )
                runCatching { onStarted.invoke() }
                Core.quickStart(
                    initParamsString,
                    paramsString,
                    stateParamsString,
                    object : InvokeInterface {
                        override fun onResult(result: String) {
                            GlobalState.launch {
                                dispatchChunked(result) { bytes, isSuccess, ack ->
                                    callback.onResult(bytes, isSuccess, ack)
                                }
                            }
                        }
                    },
                )
            }
        }

        override fun updateNotificationParams(params: NotificationParams) {
            State.notificationParamsFlow.value = params
            com.follow.clashx.common.SavedParams.saveNotificationTitle(params.title)
        }

        override fun startService(options: VpnOptions, runTime: Long, result: IResultInterface) {
            GlobalState.launch {
                State.runLock.withLock {
                    if (State.runTime != 0L) {
                        result.onResult(State.runTime)
                        return@withLock
                    }

                    runCatching { State.delegate?.unbind() }
                    State.delegate = null

                    State.options = options
                    val serviceClass: Class<out Service> =
                        if (options.enable) FlVpnService::class.java else CommonService::class.java
                    val serviceIntent = Intent(this@RemoteService, serviceClass)
                    State.intent = serviceIntent

                    val delegate = ServiceDelegate<IBaseService>(
                        serviceIntent,
                        onDisconnected = { GlobalState.log("inner service disconnected: $it") },
                    ) { binder ->
                        when (val b = binder) {
                            is CommonService.LocalBinder -> b.service as IBaseService
                            is FlVpnService.LocalBinder -> b.service as IBaseService
                            else -> null
                        }
                    }
                    State.delegate = delegate
                    delegate.bind()

                    androidx.core.content.ContextCompat.startForegroundService(
                        this@RemoteService,
                        serviceIntent,
                    )
                    val startResult = delegate.useService(timeoutMillis = 10_000L) { proxy ->
                        proxy.handleStart(options)
                    }
                    if (startResult.isFailure) {
                        GlobalState.log("startService: handleStart failed: ${startResult.exceptionOrNull()?.message}")
                        runCatching { delegate.unbind() }
                        State.delegate = null
                        State.intent = null
                        com.follow.clashx.common.SavedParams.setVpnActive(false)
                        result.onResult(0L)
                        return@withLock
                    }

                    val baseRunTime = if (runTime > 0) runTime else SystemClock.uptimeMillis()
                    State.runTime = baseRunTime
                    if (options.enable) com.follow.clashx.common.SavedParams.setVpnActive(true)
                    result.onResult(State.runTime)
                }
            }
        }

        override fun stopService(result: IResultInterface) {
            GlobalState.launch {
                State.runLock.withLock {
                    val delegate = State.delegate
                    if (delegate == null) {
                        State.runTime = 0L
                        com.follow.clashx.common.SavedParams.setVpnActive(false)
                        result.onResult(0L)
                        return@withLock
                    }
                    runCatching {
                        delegate.useService(timeoutMillis = 10_000L) { proxy ->
                            proxy.handleStop()
                        }
                    }
                    delegate.unbind()
                    State.delegate = null
                    State.intent = null
                    State.runTime = 0L
                    com.follow.clashx.common.SavedParams.setVpnActive(false)
                    result.onResult(0L)
                }
            }
        }

        override fun setEventListener(event: com.follow.clashx.service.IEventInterface?) {
            eventListener.set(event)
            if (event == null) {
                Core.setEventListener(null)
                return
            }
            Core.setEventListener(object : InvokeInterface {
                override fun onResult(result: String) {
                    val id = UUID.randomUUID().toString()
                    GlobalState.launch {
                        dispatchChunked(result) { bytes, isSuccess, ack ->
                            event.onEvent(id, bytes, isSuccess, ack)
                        }
                    }
                }
            })
        }

        override fun setState(state: String) {
            Core.setState(state)
        }

        override fun updateDns(dns: String) {
            Core.updateDns(dns)
        }

        override fun getAndroidVpnOptions(): String = Core.getAndroidVpnOptions()
        override fun getCurrentProfileName(): String = Core.getCurrentProfileName()
        override fun getRunTime(): String = Core.getRunTime()
        override fun getTraffic(): String = Core.getTraffic()
        override fun getTotalTraffic(): String = Core.getTotalTraffic()

        override fun startListener() {
            Core.startListener()
        }

        override fun stopListener() {
            Core.stopListener()
        }
    }

    override fun onBind(intent: Intent?): IBinder = stub

    override fun onCreate() {
        super.onCreate()
        runCatching { Core.getRunTime() }
            .onFailure { GlobalState.log("RemoteService: native library load failed: ${it.message}") }
        deleteStaleChannels()
        GlobalState.log("RemoteService created")
    }

    override fun onDestroy() {
        eventListener.set(null)
        runCatching { Core.setEventListener(null) }
        super.onDestroy()
    }

    private fun deleteStaleChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching { mgr.deleteNotificationChannel("FlClashX_Core") }
    }
}
