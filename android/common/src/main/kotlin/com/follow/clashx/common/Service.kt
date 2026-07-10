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
    // Plain monitor instead of a coroutine Mutex (which can't be used from the
    // non-suspend bind()/unbind()): serializes the binding/bindJob/proxyFlow
    // transition so a bind↔unbind interleave can't leave a live collect coroutine
    // running while logically unbound.
    private val lock = Any()
    private val proxyFlow: MutableStateFlow<T?> = MutableStateFlow(null)
    private var bindJob: kotlinx.coroutines.Job? = null

    // Read-only view of the live proxy: emits it on every (re)connect and null on
    // disconnect. Lets callers re-arm per-connection registrations (e.g. remote
    // state callbacks) without owning the bind lifecycle.
    val proxyUpdates: kotlinx.coroutines.flow.StateFlow<T?> get() = proxyFlow

    fun bind() {
        synchronized(lock) {
            if (!binding.compareAndSet(false, true)) return
            bindJob = GlobalState.launch {
                val self = coroutineContext[kotlinx.coroutines.Job]
                runCatching {
                    GlobalState.application.bindServiceFlow(intent).collect { binder ->
                        val proxy = binder?.let(asInterface)
                        proxyFlow.value = proxy
                        if (binder == null) onDisconnected("service disconnected: ${intent.component}")
                    }
                }.onFailure {
                    // A CancellationException here is unbind() tearing this job down
                    // deliberately — unbind already reset the state, and reporting it
                    // as a disconnect fired a spurious "crash" signal to Dart after
                    // every intentional shutdown.
                    if (it is kotlinx.coroutines.CancellationException) return@onFailure
                    // Only reset state if this is still the current bind job, so a late
                    // failure from a superseded coroutine can't clobber a fresh bind()
                    // (which would desync binding/bindJob/proxyFlow). Clears bindJob too.
                    synchronized(lock) {
                        if (bindJob === self) {
                            binding.set(false)
                            bindJob = null
                            proxyFlow.value = null
                        }
                    }
                    onDisconnected("bind failed: ${it.message}")
                }
            }
        }
    }

    fun unbind() {
        synchronized(lock) {
            if (!binding.compareAndSet(true, false)) return
            bindJob?.cancel()
            bindJob = null
            proxyFlow.value = null
        }
    }

    private class Box<R>(val v: R)

    suspend fun <R> useService(
        timeoutMillis: Long = defaultTimeoutMillis,
        block: suspend (T) -> R,
    ): Result<R> = runCatching {
        // Timeout must cover BOTH proxy acquisition and the actual (possibly
        // synchronous) binder transaction, otherwise a stalled remote leaves the
        // coroutine — and the Flutter MethodChannel result — hanging forever.
        // Box the block result so a genuine null return isn't read as a timeout:
        // only a null Box (the withTimeoutOrNull sentinel) means the deadline hit.
        val boxed = withTimeoutOrNull(timeoutMillis) {
            val proxy = proxyFlow.first { it != null }!!
            // IO, not Default: `block` is a synchronous two-way binder transaction
            // ending in a JNI call into the Go core. withTimeoutOrNull cancels the
            // coroutine but a thread blocked in a binder transaction is NOT
            // interruptible, so every timed-out probe permanently leaks one worker.
            // On the small Default pool that starves GlobalState.scope (all toggle/
            // sync/bind coroutines) → the whole native layer wedges. IO is elastic
            // (64+ threads, created on demand) so a wedged remote can't lock it out.
            withContext(Dispatchers.IO) { Box(block(proxy)) }
        } ?: error("service timed out: ${intent.component}")
        boxed.v
    }
}
