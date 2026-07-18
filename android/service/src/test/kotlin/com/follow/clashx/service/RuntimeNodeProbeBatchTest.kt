package com.follow.clashx.service

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RuntimeNodeProbeBatchTest {
    @Test
    fun boundsConcurrencyAndReturnsTheFirstCompletedSuccess() = runBlocking {
        val active = AtomicInteger(0)
        val maximumActive = AtomicInteger(0)
        val completed = ConcurrentHashMap.newKeySet<Int>()

        val selected = selectRuntimeNodeProbeIndex(
            nodeCount = 8,
            concurrency = 3,
        ) { index ->
            val current = active.incrementAndGet()
            maximumActive.updateAndGet { previous -> maxOf(previous, current) }
            try {
                delay(if (index == 2) 10L else 200L)
                completed.add(index)
                index == 2
            } finally {
                active.decrementAndGet()
            }
        }

        assertEquals(2, selected)
        assertEquals(3, maximumActive.get())
        assertEquals(setOf(2), completed)
        assertEquals(0, active.get())
    }

    @Test
    fun checksEveryNodeWhenNoCandidatePasses() = runBlocking {
        val checked = ConcurrentHashMap.newKeySet<Int>()

        val selected = selectRuntimeNodeProbeIndex(
            nodeCount = 7,
            concurrency = 4,
        ) { index ->
            checked.add(index)
            false
        }

        assertEquals(-1, selected)
        assertEquals((0 until 7).toSet(), checked)
        assertTrue(checked.size > 4)
    }
}
