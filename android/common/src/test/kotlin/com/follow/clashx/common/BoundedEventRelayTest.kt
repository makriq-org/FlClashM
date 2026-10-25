package com.follow.clashx.common

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BoundedEventRelayTest {
    @Test fun slowConsumerDoesNotBlockCommandsOrCreateAnUnboundedBacklog() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val complete = CompletableDeferred<Unit>()
        val delivered = mutableListOf<Int>()
        val relay = BoundedEventRelay<Int>(this, capacity = 3) {
            delivered.add(it)
            if (it == 0) { entered.complete(Unit); release.await() }
            if (it == 1000) complete.complete(Unit)
        }
        try {
            relay.offer(0)
            entered.await()
            // The consumer is stalled on a Binder ACK or main-thread hop.
            repeat(1000) { assertTrue(relay.offer(it + 1)) }
            val command = CompletableDeferred<Unit>()
            launch { command.complete(Unit) }
            withTimeout(1000) { command.await() }
            assertEquals(listOf(0), delivered)
            release.complete(Unit)
            withTimeout(1000) { complete.await() }
            assertEquals(listOf(0, 998, 999, 1000), delivered)
        } finally { relay.close() }
    }

    @Test fun closingAnEngineCancelsInflightDeliveryAndRejectsLateCallbacks() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val relay = BoundedEventRelay<Int>(this) {
            try { started.complete(Unit); CompletableDeferred<Unit>().await() }
            finally { cancelled.complete(Unit) }
        }
        relay.offer(1)
        started.await()
        relay.close()
        withTimeout(1000) { cancelled.await() }
        assertFalse(relay.offer(2))
    }
}
