package com.follow.clashx.common

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/** One in-flight delivery plus a bounded FIFO. Producers (including JNI/Binder
 * callbacks) never wait for Flutter. Lost UI observations recover from Go snapshots;
 * command replies must use their own reliable path, never this relay. */
class BoundedEventRelay<T>(scope: CoroutineScope, capacity: Int = 256, deliver: suspend (T) -> Unit) {
    private val queue = Channel<T>(capacity, BufferOverflow.DROP_OLDEST)
    private val worker = scope.launch {
        for (event in queue) deliver(event)
    }

    fun offer(event: T): Boolean = queue.trySend(event).isSuccess

    fun close() {
        queue.cancel()
        worker.cancel()
    }
}
