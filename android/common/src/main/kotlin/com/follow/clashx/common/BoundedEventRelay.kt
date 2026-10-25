package com.follow.clashx.common

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/** One in-flight delivery plus a bounded FIFO. Producers (including JNI/Binder
 * callbacks) never wait for Flutter. Lost UI observations recover from Go snapshots;
 * command replies must use their own reliable path, never this relay. */
class BoundedEventRelay<T>(scope: CoroutineScope, capacity: Int = 256, deliver: suspend (T) -> Unit) {
    private val queue = Channel<T>(capacity, BufferOverflow.DROP_OLDEST)
    private val worker = scope.launch {
        for (event in queue) {
            try {
                deliver(event)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // A failed UI observation must not stop subsequent deliveries.
                // Missing observations recover from the next Go snapshot.
            }
        }
    }

    fun offer(event: T): Boolean = queue.trySend(event).isSuccess

    fun close() {
        queue.cancel()
        worker.cancel()
    }
}
