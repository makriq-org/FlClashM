package com.follow.clashx.common.diagnostics

import com.google.gson.JsonParser
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

class DiagnosticRedactorTest {
    @Test
    fun redactsSharedVectorsBeforePersistence() {
        val vectors = JsonParser
            .parseString(vectorsFile().readText())
            .asJsonArray
        vectors.forEach { element ->
            val vector = element.asJsonObject
            assertEquals(
                vector["expected"].asString,
                DiagnosticRedactor.redact(vector["input"].asString),
                vector["id"].asString,
            )
        }
    }

    @Test
    fun redactsProfileLabelCutByTheUtf8Boundary() {
        val redacted = DiagnosticRedactor.redactBounded(
            "profile `${"private label ".repeat(100)}`",
            maxBytes = 128,
        )

        assertEquals(
            "profile ${DiagnosticRedactor.REPLACEMENT}" +
                DiagnosticTextLimiter.TRUNCATED_SUFFIX,
            redacted,
        )
    }

    private fun vectorsFile(): File {
        val relative = "lib/product/diagnostics/diagnostic_redaction_vectors.json"
        val workingDirectory = requireNotNull(System.getProperty("user.dir"))
        return generateSequence(File(workingDirectory).absoluteFile) {
            it.parentFile
        }.map { File(it, relative) }
            .firstOrNull(File::isFile)
            ?: error("Could not locate $relative from $workingDirectory")
    }
}
