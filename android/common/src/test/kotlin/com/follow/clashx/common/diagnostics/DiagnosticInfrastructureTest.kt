package com.follow.clashx.common.diagnostics

import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
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
}
