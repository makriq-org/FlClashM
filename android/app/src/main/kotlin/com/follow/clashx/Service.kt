package com.follow.clashx

import com.follow.clashx.common.GlobalState as CommonGlobalState
import com.follow.clashx.common.ServiceDelegate
import com.follow.clashx.common.formatString
import com.follow.clashx.common.intent
import com.follow.clashx.service.IAckInterface
import com.follow.clashx.service.ICallbackInterface
import com.follow.clashx.service.IEventInterface
import com.follow.clashx.service.IRemoteInterface
import com.follow.clashx.service.IResultInterface
import com.follow.clashx.service.IStateCallback
import com.follow.clashx.service.IVoidInterface
import com.follow.clashx.service.RemoteService
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import com.follow.clashx.service.models.NotificationParams
import com.follow.clashx.service.models.VpnOptions
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

object Service {
    // Last-resort watchdog for the ASYNC result of invokeAction/quickStart. useService
    // only bounds the synchronous registration; a stuck/lost onResult(isSuccess=true)
    // would otherwise hang the Flutter MethodChannel result forever. Sized beyond the
    // longest legitimate Dart action timeout (updateConfig/setupConfig ~2 min) so it
    // never cuts a valid slow operation short.
    private const val RESULT_WATCHDOG_MILLIS = 150_000L

    private val delegate by lazy {
        ServiceDelegate<IRemoteInterface>(
            RemoteService::class.intent,
            onDisconnected = { handleServiceDisconnected(it) },
        ) { binder ->
            IRemoteInterface.Stub.asInterface(binder)
        }
    }

    var onServiceDisconnected: ((String) -> Unit)? = null

    private fun handleServiceDisconnected(message: String) {
        onServiceDisconnected?.invoke(message)
    }

    /** Parsed StateHub snapshot pushed from :remote (see [IStateCallback]). */
    data class RemoteState(
        val state: String,
        val startedAt: Long,
        val message: String,
        val seq: Long,
    ) {
        val isRunning get() = state == "running"
        val isStarting get() = state == "starting"
    }

    // Last state pushed by the :remote StateHub; null until the first snapshot
    // arrives (pre-bind). GlobalState collects this to drive the UI-facing
    // runStateFlow — :main no longer derives run-state on its own.
    val remoteStateFlow = MutableStateFlow<RemoteState?>(null)

    private fun parseState(json: String?): RemoteState? = runCatching {
        val o = JSONObject(json ?: return null)
        RemoteState(
            o.optString("state", ""),
            o.optLong("startedAt", 0L),
            o.optString("message", ""),
            o.optLong("seq", 0L),
        )
    }.getOrNull()?.takeIf { it.state.isNotBlank() }

    private val stateCallback = object : IStateCallback.Stub() {
        override fun onStateChanged(stateJson: String?) {
            remoteStateFlow.value = parseState(stateJson) ?: return
        }
    }

    private val stateWiringStarted = AtomicBoolean(false)

    // Re-register on every (re)connect: a recycled :remote process has a fresh
    // RemoteCallbackList, and registration delivers the current snapshot — which
    // doubles as the post-reconnect state sync.
    private fun ensureStateWiring() {
        if (!stateWiringStarted.compareAndSet(false, true)) return
        CommonGlobalState.launch {
            delegate.proxyUpdates.collect { proxy ->
                if (proxy == null) return@collect
                runCatching { proxy.registerStateCallback(stateCallback) }
                    .onFailure { CommonGlobalState.log("registerStateCallback failed: ${it.message}") }
            }
        }
    }

    /** One-shot pull of the StateHub snapshot; null when :remote is unreachable. */
    suspend fun fetchServiceState(): RemoteState? =
        delegate.useService { it.serviceState }.getOrNull()?.let { parseState(it) }

    fun bind() {
        delegate.bind()
        ensureStateWiring()
    }

    fun unbind() {
        delegate.unbind()
    }

    suspend fun invokeAction(data: String, cb: ((String) -> Unit)?): Result<Unit> {
        val chunks = Collections.synchronizedList(mutableListOf<ByteArray>())
        val delivered = AtomicBoolean(false)
        var watchdog: Job? = null
        // Deliver the payload to cb exactly once, whether it arrives via the real
        // onResult(isSuccess=true), a registration failure, or the watchdog timeout.
        fun deliver(payload: String) {
            if (delivered.compareAndSet(false, true)) {
                watchdog?.cancel()
                cb?.invoke(payload)
            }
        }
        val outcome = delegate.useService { proxy ->
            proxy.invokeAction(data, object : ICallbackInterface.Stub() {
                override fun onResult(result: ByteArray?, isSuccess: Boolean, ack: IAckInterface?) {
                    chunks.add(result ?: byteArrayOf())
                    ack?.onAck()
                    if (isSuccess) deliver(chunks.formatString())
                }
            })
        }
        if (outcome.isFailure) {
            // Registration failed: onResult will never fire, so resolve cb now.
            deliver("")
        } else if (!delivered.get()) {
            // Registration succeeded but the async result is not covered by useService:
            // arm a watchdog so a lost/stuck remote callback can't hang cb forever.
            watchdog = CommonGlobalState.launch {
                delay(RESULT_WATCHDOG_MILLIS)
                deliver("")
            }
        }
        return outcome
    }

    suspend fun quickStart(
        initParamsString: String,
        paramsString: String,
        stateParamsString: String,
        onStarted: (() -> Unit)?,
        onResult: ((String) -> Unit)?,
    ): Result<Unit> {
        val chunks = Collections.synchronizedList(mutableListOf<ByteArray>())
        val delivered = AtomicBoolean(false)
        var watchdog: Job? = null
        // Deliver to onResult exactly once (real onResult / registration failure /
        // watchdog). onStarted is a separate fire-and-forget signal, left untouched.
        fun deliver(payload: String) {
            if (delivered.compareAndSet(false, true)) {
                watchdog?.cancel()
                onResult?.invoke(payload)
            }
        }
        val outcome = delegate.useService { proxy ->
            proxy.quickStart(
                initParamsString,
                paramsString,
                stateParamsString,
                object : ICallbackInterface.Stub() {
                    override fun onResult(result: ByteArray?, isSuccess: Boolean, ack: IAckInterface?) {
                        chunks.add(result ?: byteArrayOf())
                        ack?.onAck()
                        if (isSuccess) deliver(chunks.formatString())
                    }
                },
                object : IVoidInterface.Stub() {
                    override fun invoke() {
                        onStarted?.invoke()
                    }
                },
            )
        }
        if (outcome.isFailure) {
            deliver("")
        } else if (!delivered.get()) {
            watchdog = CommonGlobalState.launch {
                delay(RESULT_WATCHDOG_MILLIS)
                deliver("")
            }
        }
        return outcome
    }

    // Serializes listener (re)registration and tracks which caller owns the current
    // one, so a detach-time cleanup can drop the remote listener ONLY while its own
    // registration is still current. Activity recreation can run the new engine's
    // init BEFORE the old engine's detach — an unguarded trailing null would wipe
    // the fresh listener and leave the new UI with empty logs/traffic.
    private val listenerLock = Mutex()
    private val listenerOwner = AtomicReference<Any?>(null)

    suspend fun setEventListener(cb: ((String?) -> Unit)?, owner: Any? = null): Result<Unit> =
        listenerLock.withLock {
            listenerOwner.set(owner)
            sendEventListener(cb)
        }

    /** Detach-time cleanup: unregister the remote listener unless someone else has
     *  since registered their own (see [listenerLock] docs). */
    suspend fun clearEventListener(owner: Any) {
        listenerLock.withLock {
            if (listenerOwner.get() !== owner) return
            listenerOwner.set(null)
            sendEventListener(null)
        }
    }

    private suspend fun sendEventListener(cb: ((String?) -> Unit)?): Result<Unit> {
        val buffers = ConcurrentHashMap<String, MutableList<ByteArray>>()
        // Allow a slow cold-start bind (matches Dart's 15s init timeout) so the event
        // stream still registers instead of silently giving up after the 5s default.
        return delegate.useService(timeoutMillis = 15_000L) { proxy ->
            proxy.setEventListener(
                if (cb == null) null else object : IEventInterface.Stub() {
                    override fun onEvent(
                        id: String,
                        data: ByteArray?,
                        isSuccess: Boolean,
                        ack: IAckInterface?,
                    ) {
                        val list = buffers.getOrPut(id) { Collections.synchronizedList(mutableListOf()) }
                        list.add(data ?: byteArrayOf())
                        ack?.onAck()
                        if (isSuccess) {
                            cb(list.formatString())
                            buffers.remove(id)
                        }
                    }
                },
            )
        }
    }

    suspend fun updateNotificationParams(params: NotificationParams): Result<Unit> =
        delegate.useService { it.updateNotificationParams(params) }

    private suspend fun awaitResult(block: (IResultInterface) -> Unit): Long =
        suspendCancellableCoroutine { cont ->
            val cb = object : IResultInterface.Stub() {
                override fun onResult(runTime: Long) {
                    if (cont.isActive) cont.resume(runTime)
                }
            }
            runCatching { block(cb) }.onFailure {
                if (cont.isActive) cont.resumeWithException(it)
            }
        }

    // 35s, not 30s: the remote side itself allows handleStart up to 30s (plus bind +
    // FGS-start overhead) and always answers via onResult, including its fail paths.
    // An equal deadline let this side give up a moment before a barely-in-time start
    // reported success, desyncing the UI from a tunnel that actually came up. Still
    // comfortably under Dart's 60s wait.
    suspend fun startService(options: VpnOptions, runTime: Long): Long =
        delegate.useService(timeoutMillis = 35_000L) { proxy ->
            awaitResult { cb -> proxy.startService(options, runTime, cb) }
        }.getOrNull() ?: 0L

    suspend fun stopService(): Long =
        delegate.useService(timeoutMillis = 15_000L) { proxy ->
            awaitResult { cb -> proxy.stopService(cb) }
        }.getOrNull() ?: 0L

    suspend fun setState(state: String): Result<Unit> =
        delegate.useService { it.setState(state) }

    suspend fun updateDns(dns: String): Result<Unit> =
        delegate.useService { it.updateDns(dns) }

    suspend fun getAndroidVpnOptions(): String =
        delegate.useService { it.androidVpnOptions }.getOrNull() ?: ""

    suspend fun getAppliedAndroidVpnOptions(): String =
        delegate.useService { it.appliedAndroidVpnOptions }.getOrNull() ?: ""

    suspend fun getCurrentProfileName(): String =
        delegate.useService { it.currentProfileName }.getOrNull() ?: ""

    suspend fun getTraffic(): String =
        delegate.useService { it.traffic }.getOrNull() ?: ""

    suspend fun getTotalTraffic(): String =
        delegate.useService { it.totalTraffic }.getOrNull() ?: ""

    suspend fun startRuntimeNode(
        nodeId: String,
        executablePath: String,
        workingDirectory: String,
        arguments: List<String> = emptyList(),
    ): Long =
        delegate.useService(timeoutMillis = 15_000L) { proxy ->
            awaitResult { cb ->
                proxy.startRuntimeNode(
                    nodeId,
                    executablePath,
                    workingDirectory,
                    arguments,
                    cb,
                )
            }
        }.getOrNull() ?: 0L

    suspend fun stopRuntimeNode(nodeId: String): Long =
        delegate.useService(timeoutMillis = 15_000L) { proxy ->
            awaitResult { cb -> proxy.stopRuntimeNode(nodeId, cb) }
        }.getOrNull() ?: 0L

    suspend fun getRuntimeNodeRunTime(nodeId: String): Long =
        delegate.useService { it.getRuntimeNodeRunTime(nodeId) }.getOrNull() ?: 0L

    suspend fun getRuntimeNodeLastError(nodeId: String): String =
        delegate.useService { it.getRuntimeNodeLastError(nodeId) }.getOrNull() ?: ""

    suspend fun startListener(): Result<Unit> =
        delegate.useService { it.startListener() }

    suspend fun stopListener(): Result<Unit> =
        delegate.useService { it.stopListener() }
}
