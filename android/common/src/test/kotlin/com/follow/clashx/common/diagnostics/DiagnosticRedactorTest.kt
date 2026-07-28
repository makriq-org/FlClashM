package com.follow.clashx.common.diagnostics

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DiagnosticRedactorTest {
    @Test
    fun redactsSecretsBeforePersistence() {
        val input = listOf(
            """password: "hunter2" token=abc123""",
            "Authorization: Bearer very-secret-token",
            "subscription_url=https://user:pass@example.com/sub/private?token=abc",
            "profile `My private profile` failed",
            """raw config={"proxies":[{"password":"inside-config"}]}""",
            """name: "Node from JSON"""",
            "ipc payload={\n  \"password\": \"second-line-secret\"\n}",
        ).joinToString("\n")

        val redacted = DiagnosticRedactor.redact(input)

        listOf(
            "hunter2",
            "abc123",
            "very-secret-token",
            "user:pass",
            "/sub/private",
            "My private profile",
            "Node from JSON",
            "\"proxies\"",
            "inside-config",
            "second-line-secret",
        ).forEach { secret ->
            assertFalse(redacted.contains(secret), "Leaked $secret in $redacted")
        }
        assertTrue(redacted.contains(DiagnosticRedactor.REPLACEMENT))
    }
}
