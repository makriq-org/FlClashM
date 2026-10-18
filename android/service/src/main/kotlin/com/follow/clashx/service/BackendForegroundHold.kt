package com.follow.clashx.service

import android.content.Intent
import androidx.core.content.ContextCompat
import com.follow.clashx.common.GlobalState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.withTimeout

interface BackendForegroundResource : IBaseService {
    fun finishIfIdle()
}

/** A resource reference count controlled exclusively by Go operation IDs. */
internal object BackendForegroundHold {
    const val ACTION_HOLD = "com.makriq.flclash.backend.HOLD"
    const val ACTION_RUNTIME = "com.makriq.flclash.backend.RUNTIME_RESOURCE"
    private val lock = Any()
    private val holds = mutableMapOf<String, CompletableDeferred<Unit>>()
    private val runtimeStarts = mutableMapOf<String, CompletableDeferred<Unit>>()
    private val services = mutableSetOf<BackendForegroundResource>()
    private val available = MutableStateFlow<List<BackendForegroundResource>>(emptyList())
    val held: Boolean get() = synchronized(lock) { holds.isNotEmpty() }

    suspend fun acquire(id: String) {
        val ready = synchronized(lock) {
            holds.getOrPut(id) { CompletableDeferred() }.also {
                if (services.any { service -> !service.destroyed }) it.complete(Unit)
            }
        }
        try {
            if (!ready.isCompleted) {
                val context = GlobalState.application
                ContextCompat.startForegroundService(context,
                    Intent(context, CommonService::class.java).setAction(ACTION_HOLD).putExtra("operationId", id))
            }
            withTimeout(10_000L) { ready.await() }
        } catch (error: Throwable) {
            release(id)
            throw error
        }
    }

    suspend fun retainRuntime(id: String) {
        val ready = CompletableDeferred<Unit>()
        synchronized(lock) { check(runtimeStarts.putIfAbsent(id, ready) == null) }
        try {
            val context = GlobalState.application
            ContextCompat.startForegroundService(context,
                Intent(context, CommonService::class.java).setAction(ACTION_RUNTIME).putExtra("operationId", id))
            withTimeout(10_000L) { ready.await() }
        } finally { synchronized(lock) { runtimeStarts.remove(id) } }
    }
    fun acknowledgeRuntime(id: String?, promoted: Boolean) {
        val waiter = synchronized(lock) { runtimeStarts[id] }
        if (promoted) waiter?.complete(Unit)
        else waiter?.completeExceptionally(IllegalStateException("foreground host promotion failed"))
    }

    fun created(service: BackendForegroundResource) = synchronized(lock) {
        services.add(service)
        available.value = services.toList()
    }
    fun destroyed(service: BackendForegroundResource) = synchronized(lock) {
        services.remove(service)
        available.value = services.toList()
    }
    suspend fun awaitService(type: Class<out android.app.Service>): BackendForegroundResource = withTimeout(30_000L) {
        available.mapNotNull { values -> values.firstOrNull { !it.destroyed && type.isInstance(it) } }.first()
    }
    fun acknowledge(id: String?, promoted: Boolean) {
        val waiter = synchronized(lock) { holds[id] }
        if (promoted) waiter?.complete(Unit)
        else waiter?.completeExceptionally(IllegalStateException("foreground promotion failed"))
        finishIdle()
    }
    fun release(id: String) {
        synchronized(lock) { holds.remove(id) }
        finishIdle()
    }
    fun finishIdle() {
        val idle = synchronized(lock) { if (holds.isEmpty()) services.toList() else emptyList() }
        idle.forEach { it.finishIfIdle() }
    }
}
