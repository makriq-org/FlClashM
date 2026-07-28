package com.follow.clashx.common.diagnostics

object DiagnosticRedactor {
    const val REPLACEMENT = "<redacted>"
    const val URL_REPLACEMENT = "<redacted-url>"

    private val url =
        Regex("""(?:https?|socks5?|ss|trojan|vmess|vless)://[^\s<>"']+""", RegexOption.IGNORE_CASE)
    private val authorization =
        Regex("""\b(?:bearer|basic)\s+[a-z0-9._~+/=-]+""", RegexOption.IGNORE_CASE)
    private val sensitivePair = Regex(
        """(["']?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|auth|authorization|proxy[_-]?authorization|api[_-]?key|apikey|subscription(?:[_-]?url)?|support[_-]?url|username|profile[_-]?(?:name|title)|currentProfileName|node[_-]?name)["']?\s*[:=]\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s,;}\]]+)""",
        RegexOption.IGNORE_CASE,
    )
    private val sensitiveArgument = Regex(
        """(--(?:password|passwd|token|secret|auth|authorization|api[_-]?key|subscription[_-]?url|support[_-]?url|username)(?:=|\s+))(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s]+)""",
        RegexOption.IGNORE_CASE,
    )
    private val profileLabel = Regex(
        """(\b(?:profile|node)\s+(?:name\s+)?)(?:`[^`]*(?:`|$)|"[^"]*(?:"|$)|'[^']*(?:'|$))""",
        RegexOption.IGNORE_CASE,
    )
    private val rawPayload = Regex(
        """(\b(?:raw(?:[\s_-]?(?:config|data|payload))?|ipc[\s_-]?payload|quickstart[\s_-]?params|profile[\s_-]?yaml|subscription[\s_-]?content)\s*[:=]\s*)(?:\{.*|\[.*|.+)$""",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )

    fun redact(value: String): String {
        if (value.isEmpty()) return value
        return value
            .replace(url, URL_REPLACEMENT)
            .replace(authorization, REPLACEMENT)
            .replace(sensitivePair) { "${it.groupValues[1]}$REPLACEMENT" }
            .replace(sensitiveArgument) { "${it.groupValues[1]}$REPLACEMENT" }
            .replace(profileLabel) { "${it.groupValues[1]}$REPLACEMENT" }
            .replace(rawPayload) { "${it.groupValues[1]}$REPLACEMENT" }
    }

    fun redactBounded(
        value: String,
        maxBytes: Int = MAX_DIAGNOSTIC_ENTRY_BYTES,
    ): String {
        val bounded = DiagnosticTextLimiter.truncateUtf8(value, maxBytes)
        val wasTruncated =
            bounded.length != value.length ||
                bounded.endsWith(DiagnosticTextLimiter.TRUNCATED_SUFFIX)
        val redacted = redact(bounded)
        if (!wasTruncated) {
            return DiagnosticTextLimiter.truncateUtf8(redacted, maxBytes)
        }
        if (redacted.endsWith(DiagnosticTextLimiter.TRUNCATED_SUFFIX)) {
            return DiagnosticTextLimiter.truncateUtf8(redacted, maxBytes)
        }
        val suffix = DiagnosticTextLimiter.TRUNCATED_SUFFIX
        val suffixBytes = DiagnosticTextLimiter.utf8Length(suffix)
        if (suffixBytes > maxBytes) {
            return DiagnosticTextLimiter.truncateUtf8(
                redacted,
                maxBytes,
                suffix = "",
            )
        }
        val content = DiagnosticTextLimiter.truncateUtf8(
            redacted,
            maxBytes - suffixBytes,
            suffix = "",
        )
        return content + suffix
    }
}
