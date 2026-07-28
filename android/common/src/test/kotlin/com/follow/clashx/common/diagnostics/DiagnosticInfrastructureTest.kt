package com.follow.clashx.common.diagnostics

import java.io.ByteArrayInputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DiagnosticInfrastructureTest {
    @Test
    fun boundedReaderDiscardsHugeLineTailAndKeepsUtf8Boundary() {
        val payload = ("界".repeat(400_000) + "\nnext-line\n")
            .toByteArray(StandardCharsets.UTF_8)
        val lines = mutableListOf<String>()

        BoundedUtf8LineReader(
            ByteArrayInputStream(payload),
            maxLineBytes = 64,
        ).use { reader ->
            reader.forEachLine(lines::add)
        }

        assertEquals(2, lines.size)
        assertTrue(lines.first().endsWith("…<truncated>"))
        assertTrue(lines.first().toByteArray(StandardCharsets.UTF_8).size <= 64)
        assertFalse(lines.first().contains('\uFFFD'))
        assertEquals("next-line", lines.last())
    }

    @Test
    fun boundedReaderTreatsCarriageReturnAsALineTerminator() {
        val lines = mutableListOf<String>()

        BoundedUtf8LineReader(
            ByteArrayInputStream("first\rsecond\r\nthird\n".toByteArray()),
        ).use { reader ->
            reader.forEachLine(lines::add)
        }

        assertEquals(listOf("first", "second", "third"), lines)
    }

    @Test
    fun throwableRendererBoundsHugeMessagesBeforeRenderingStack() {
        val rendered = DiagnosticThrowableRenderer.render(
            context = "uncaught test exception",
            error = IllegalStateException("界".repeat(400_000)),
            maxBytes = 128,
        )

        assertTrue(rendered.toByteArray(StandardCharsets.UTF_8).size <= 128)
        assertTrue(rendered.endsWith("…<truncated>"))
        assertFalse(rendered.contains('\uFFFD'))
        assertTrue(rendered.startsWith("uncaught test exception"))
    }

    @Test
    fun writerKeepsRecentEntriesInFifoOrderAndBatchesThem() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val written = Collections.synchronizedList(mutableListOf<String>())
        val batchSizes = Collections.synchronizedList(mutableListOf<Int>())
        val dropped = AtomicInteger(0)
        val queue = DiagnosticWriteQueue(
            capacity = 3,
            writeBatch = { lines ->
                if (lines.first() == "active") {
                    started.countDown()
                    release.await(2, TimeUnit.SECONDS)
                }
                batchSizes.add(lines.size)
                written.addAll(lines)
            },
            onDropped = dropped::addAndGet,
        )
        try {
            queue.offer("active")
            assertTrue(started.await(2, TimeUnit.SECONDS))
            queue.offer("oldest")
            queue.offer("newer")
            queue.offer("newest")
            queue.offer("latest")

            release.countDown()
            assertTrue(queue.flush(2_000L))

            assertEquals(1, dropped.get())
            assertEquals(listOf("active", "newer", "newest", "latest"), written)
            assertEquals(listOf(1, 3), batchSizes)
        } finally {
            release.countDown()
            queue.shutdownNow()
        }
    }

    @Test
    fun failedBatchDoesNotKillWriter() {
        val attempts = AtomicInteger(0)
        val written = Collections.synchronizedList(mutableListOf<String>())
        val queue = DiagnosticWriteQueue(
            capacity = 4,
            writeBatch = { lines ->
                if (attempts.incrementAndGet() == 1) throw IOException("disk full")
                written.addAll(lines)
            },
        )
        try {
            queue.offer("fails")
            assertTrue(queue.flush(2_000L))
            queue.offer("survives")
            assertTrue(queue.flush(2_000L))

            assertEquals(listOf("survives"), written)
        } finally {
            queue.shutdownNow()
        }
    }

    @Test
    fun interruptedFlushRestoresTheInterruptFlag() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val queue = DiagnosticWriteQueue(
            capacity = 4,
            writeBatch = {
                started.countDown()
                release.await(2, TimeUnit.SECONDS)
            },
        )
        try {
            queue.offer("blocked")
            assertTrue(started.await(2, TimeUnit.SECONDS))
            Thread.currentThread().interrupt()
            assertFalse(queue.flush(2_000L))
            assertTrue(Thread.interrupted())

            release.countDown()
            assertTrue(queue.flush(2_000L))
        } finally {
            Thread.interrupted()
            release.countDown()
            queue.shutdownNow()
        }
    }
}
