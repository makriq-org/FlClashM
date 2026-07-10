package com.follow.clashx.common

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.retryWhen
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean

fun Context.bindServiceFlow(
    intent: Intent,
    flags: Int = Context.BIND_AUTO_CREATE,
    maxRetries: Int = 5,
    initialDelayMillis: Long = 500L,
): Flow<IBinder?> = callbackFlow {
    val connection = object : ServiceConnection {
        // No linkToDeath: the framework already delivers onServiceDisconnected when
        // the :remote process dies. A DeathRecipient here only duplicated the signal
        // (inflating the Dart crash counter) and leaked recipients across rebinds.
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            trySend(binder)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            trySend(null)
        }

        override fun onBindingDied(name: ComponentName?) {
            close(IllegalStateException("binding died for $name"))
        }

        override fun onNullBinding(name: ComponentName?) {
            close(IllegalStateException("null binding for $name"))
        }
    }
    val bound = bindService(intent, connection, flags)
    if (!bound) {
        close(IllegalStateException("bindService returned false for ${intent.component}"))
        return@callbackFlow
    }
    awaitClose { runCatching { unbindService(connection) } }
}.retryWhen { cause, attempt ->
    val retry = attempt < maxRetries && cause is Exception
    if (retry) {
        val backoff = initialDelayMillis * (1L shl attempt.toInt().coerceAtMost(4))
        delay(backoff)
    }
    retry
}

class ServiceDelegate<T : Any>(
    private val intent: Intent,
    private val onDisconnected: (String) -> Unit = {},
    private val defaultTimeoutMillis: Long = 5_000L,
    private val asInterface: (IBinder) -> T?,
) {
    private val binding = AtomicBoolean(false)
    private val lock = Mutex()
    private val proxyFlow: MutableStateFlow<T?> = MutableStateFlow(null)
    private var bindJob: kotlinx.coroutines.Job? = null

    fun bind() {
        if (!binding.compareAndSet(false, true)) return
        bindJob = GlobalState.launch {
            runCatching {
                GlobalState.application.bindServiceFlow(intent).collect { binder ->
                    val proxy = binder?.let(asInterface)
                    proxyFlow.value = proxy
                    if (binder == null) onDisconnected("service disconnected: ${intent.component}")
                }
            }.onFailure {
                onDisconnected("bind failed: ${it.message}")
                binding.set(false)
                proxyFlow.value = null
            }
        }
    }

    fun unbind() {
        if (!binding.compareAndSet(true, false)) return
        bindJob?.cancel()
        bindJob = null
        proxyFlow.value = null
    }

    suspend fun <R> useService(
        timeoutMillis: Long = defaultTimeoutMillis,
        block: suspend (T) -> R,
    ): Result<R> = runCatching {
        // Timeout must cover BOTH proxy acquisition and the actual (possibly
        // synchronous) binder transaction, otherwise a stalled remote leaves the
        // coroutine — and the Flutter MethodChannel result — hanging forever.
        withTimeoutOrNull(timeoutMillis) {
            val proxy = proxyFlow.first { it != null }!!
            withContext(Dispatchers.Default) { block(proxy) }
        } ?: error("service timed out: ${intent.component}")
    }
}
