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
    private val eventDeathRecipient = AtomicReference<IBinder.DeathRecipient?>(null)

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
                        runCatching { result.onResult(State.runTime) }
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

                    val fgsResult = runCatching {
                        androidx.core.content.ContextCompat.startForegroundService(
                            this@RemoteService,
                            serviceIntent,
                        )
                    }
                    if (fgsResult.isFailure) {
                        // FGS start can be rejected (e.g. ForegroundServiceStartNotAllowed
                        // when the UID races to background on Android 12+). Fail fast and
                        // unwind instead of letting the Dart caller hang for the full
                        // timeout while an empty auto-created foreground service lingers.
                        GlobalState.log("startService: startForegroundService failed: ${fgsResult.exceptionOrNull()?.message}")
                        runCatching { delegate.unbind() }
                        State.delegate = null
                        State.intent = null
                        com.follow.clashx.common.SavedParams.setVpnActive(false)
                        runCatching { result.onResult(0L) }
                        return@withLock
                    }
                    val startResult = delegate.useService(timeoutMillis = 10_000L) { proxy ->
                        proxy.handleStart(options)
                    }
                    if (startResult.isFailure) {
                        GlobalState.log("startService: handleStart failed: ${startResult.exceptionOrNull()?.message}")
                        runCatching { delegate.unbind() }
                        State.delegate = null
                        State.intent = null
                        com.follow.clashx.common.SavedParams.setVpnActive(false)
                        runCatching { result.onResult(0L) }
                        return@withLock
                    }

                    val baseRunTime = if (runTime > 0) runTime else SystemClock.uptimeMillis()
                    State.runTime = baseRunTime
                    if (options.enable) com.follow.clashx.common.SavedParams.setVpnActive(true)
                    runCatching { result.onResult(State.runTime) }
                }
            }
        }

        override fun stopService(result: IResultInterface) {
            GlobalState.launch {
                State.runLock.withLock {
                    val delegate = State.delegate
                    if (delegate == null) {
                        // A headless cold-start (tile/widget/Always-on) brings the tunnel up
                        // without ever assigning State.delegate. If something is still running,
                        // signal the worker services to tear themselves down so an in-app stop
                        // actually kills the TUN/core instead of just zeroing the UI state.
                        if (State.runTime != 0L) {
                            runCatching {
                                val stop = Intent(this@RemoteService, FlVpnService::class.java)
                                    .setAction(FlVpnService.ACTION_STOP)
                                androidx.core.content.ContextCompat.startForegroundService(this@RemoteService, stop)
                            }
                            runCatching {
                                val stop = Intent(this@RemoteService, CommonService::class.java)
                                    .setAction(FlVpnService.ACTION_STOP)
                                androidx.core.content.ContextCompat.startForegroundService(this@RemoteService, stop)
                            }
                        }
                        State.runTime = 0L
                        com.follow.clashx.common.SavedParams.setVpnActive(false)
                        runCatching { result.onResult(0L) }
                        return@withLock
                    }
                    runCatching {
                        delegate.useService(timeoutMillis = 10_000L) { proxy ->
                            proxy.handleStop()
                        }
                    }
                    runCatching { RuntimeNodeProcessManager.stopAll() }
                    delegate.unbind()
                    State.delegate = null
                    State.intent = null
                    State.runTime = 0L
                    com.follow.clashx.common.SavedParams.setVpnActive(false)
                    runCatching { result.onResult(0L) }
                }
            }
        }

        override fun setEventListener(event: com.follow.clashx.service.IEventInterface?) {
            val prev = eventListener.getAndSet(event)
            // Release the death recipient linked to the previous listener's binder.
            eventDeathRecipient.getAndSet(null)?.let { r ->
                runCatching { prev?.asBinder()?.unlinkToDeath(r, 0) }
            }
            if (event == null) {
                Core.setEventListener(null)
                return
            }
            // Proactively stop dispatching the instant the :app proxy dies instead of
            // waiting for RemoteService.onDestroy.
            val recipient = IBinder.DeathRecipient {
                if (eventListener.compareAndSet(event, null)) {
                    runCatching { Core.setEventListener(null) }
                }
            }
            eventDeathRecipient.set(recipient)
            runCatching { event.asBinder().linkToDeath(recipient, 0) }
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

        override fun startRuntimeNode(
            nodeId: String,
            executablePath: String,
            workingDirectory: String,
            arguments: MutableList<String>,
            result: IResultInterface,
        ) {
            GlobalState.launch {
                val startTime = RuntimeNodeProcessManager.start(
                    nodeId = nodeId,
                    executablePath = executablePath,
                    workingDirectory = workingDirectory,
                    arguments = arguments,
                )
                result.onResult(startTime)
            }
        }

        override fun stopRuntimeNode(nodeId: String, result: IResultInterface) {
            GlobalState.launch {
                val stoppedAt = RuntimeNodeProcessManager.stop(nodeId)
                result.onResult(stoppedAt)
            }
        }

        override fun getRuntimeNodeRunTime(nodeId: String): Long =
            RuntimeNodeProcessManager.readStartTime(nodeId)

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
        val ev = eventListener.getAndSet(null)
        eventDeathRecipient.getAndSet(null)?.let { r ->
            runCatching { ev?.asBinder()?.unlinkToDeath(r, 0) }
        }
        runCatching { Core.setEventListener(null) }
        GlobalState.launch { RuntimeNodeProcessManager.stopAll() }
        super.onDestroy()
    }

    private fun deleteStaleChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching { mgr.deleteNotificationChannel("FlClashX") }
        runCatching { mgr.deleteNotificationChannel("FlClashX_Subscription") }
        runCatching { mgr.deleteNotificationChannel("FlClashX_Core") }
    }
}
