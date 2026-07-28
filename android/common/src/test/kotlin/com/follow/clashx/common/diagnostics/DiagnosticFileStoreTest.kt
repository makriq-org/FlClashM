package com.follow.clashx.common.diagnostics

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DiagnosticFileStoreTest {
    @Test
    fun rotatesAndBoundsRetainedFiles() {
        val temporary = Files.createTempDirectory("diagnostic-store")
        try {
            val store = DiagnosticFileStore(
                directory = temporary.toFile(),
                source = "runtime-naiveproxy",
                maxFileBytes = 80,
                maxFiles = 3,
            )

            repeat(12) { index ->
                store.append("entry-$index-${"x".repeat(28)}\n")
            }

            val files = store.files()
            assertEquals(3, files.size)
            assertTrue(files.all { it.length() <= 80 })
            assertTrue(files.joinToString("") { it.readText() }.contains("entry-11"))
        } finally {
            temporary.toFile().deleteRecursively()
        }
    }

    @Test
    fun boundsMultibyteEntriesByUtf8Bytes() {
        val temporary = Files.createTempDirectory("diagnostic-store-utf8")
        try {
            val store = DiagnosticFileStore(
                directory = temporary.toFile(),
                source = "android-main",
                maxFileBytes = 10,
                maxFiles = 2,
            )

            store.append("界".repeat(20))

            val file = store.files().single()
            assertTrue(file.length() <= 10)
            assertEquals("界界界", file.readText())
            assertTrue(!file.readText().contains('\uFFFD'))
        } finally {
            temporary.toFile().deleteRecursively()
        }
    }
}
