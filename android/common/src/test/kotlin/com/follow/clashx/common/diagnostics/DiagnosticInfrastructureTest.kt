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
    fun protectedTasksDisplaceBestEffortTasksFirst() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = Collections.synchronizedList(mutableListOf<String>())
        val dropped = AtomicInteger(0)
        val queue = DiagnosticTaskQueue(
            capacity = 4,
            protectedReserve = 2,
            onDropped = dropped::addAndGet,
        )
        try {
            queue.offer(
                Runnable {
                    started.countDown()
                    release.await(2, TimeUnit.SECONDS)
                    completed.add("active")
                },
                protected = false,
            )
            assertTrue(started.await(2, TimeUnit.SECONDS))
            queue.offer(Runnable { completed.add("old-noisy") }, protected = false)
            queue.offer(Runnable { completed.add("new-noisy") }, protected = false)
            queue.offer(Runnable { completed.add("warning") }, protected = true)
            queue.offer(Runnable { completed.add("lifecycle-1") }, protected = true)
            queue.offer(Runnable { completed.add("lifecycle-2") }, protected = true)

            release.countDown()
            assertTrue(queue.flush(2_000L))

            assertEquals(1, dropped.get())
            assertFalse(completed.contains("old-noisy"))
            assertTrue(completed.containsAll(listOf("warning", "lifecycle-1", "lifecycle-2")))
        } finally {
            release.countDown()
            queue.shutdownNow()
        }
    }

    @Test
    fun failedWriteDoesNotKillQueueWorker() {
        val uncaught = AtomicInteger(0)
        val completed = AtomicInteger(0)
        val queue = DiagnosticTaskQueue(
            capacity = 4,
            protectedReserve = 1,
            threadFactory = { task ->
                Thread(task, "diagnostic-test-writer").apply {
                    uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, _ ->
                        uncaught.incrementAndGet()
                    }
                }
            },
        )
        try {
            queue.offer(
                Runnable { throw IOException("disk full") },
                protected = false,
            )
            queue.offer(
                Runnable { completed.incrementAndGet() },
                protected = true,
            )

            assertTrue(queue.flush(2_000L))
            assertEquals(1, completed.get())
            assertEquals(0, uncaught.get())
        } finally {
            queue.shutdownNow()
        }
    }

    @Test
    fun persistenceFailureRemainsVisibleToLaterFlushes() {
        val reported = AtomicInteger(0)
        val health = DiagnosticPersistenceHealth {
            reported.incrementAndGet()
        }

        assertFalse(health.run { throw IOException("disk full") })
        assertTrue(health.run { Unit })

        assertFalse(health.isHealthy)
        assertEquals(1, reported.get())
    }

    @Test
    fun flushWaitsForAcceptedSynchronousWrites() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val queue = DiagnosticTaskQueue(
            capacity = 4,
            protectedReserve = 1,
        )
        val writer = Thread {
            queue.runSynchronously(
                Runnable {
                    started.countDown()
                    release.await(2, TimeUnit.SECONDS)
                },
            )
        }
        try {
            writer.start()
            assertTrue(started.await(2, TimeUnit.SECONDS))
            assertFalse(queue.flush(50L))

            release.countDown()
            writer.join(2_000L)
            assertTrue(queue.flush(2_000L))
        } finally {
            release.countDown()
            writer.join(2_000L)
            queue.shutdownNow()
        }
    }

    @Test
    fun controlTaskTimeoutDoesNotWaitForStalledPersistence() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val queue = DiagnosticTaskQueue(
            capacity = 4,
            protectedReserve = 1,
        )
        try {
            val id = requireNotNull(
                queue.offerControl(
                    Runnable {
                        started.countDown()
                        release.await(2, TimeUnit.SECONDS)
                    },
                ),
            )
            assertTrue(started.await(2, TimeUnit.SECONDS))
            assertFalse(queue.awaitCompletion(id, TimeUnit.MILLISECONDS.toNanos(50)))

            release.countDown()
            assertTrue(
                queue.awaitCompletion(id, TimeUnit.SECONDS.toNanos(2)),
            )
        } finally {
            release.countDown()
            queue.shutdownNow()
        }
    }
}
