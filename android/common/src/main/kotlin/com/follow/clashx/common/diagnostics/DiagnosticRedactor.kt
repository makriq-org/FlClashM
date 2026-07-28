package com.follow.clashx.common.diagnostics

object DiagnosticRedactor {
    const val REPLACEMENT = "<redacted>"
    const val URL_REPLACEMENT = "<redacted-url>"

    private val url =
        Regex("""(?:https?|socks5?|ss|trojan|vmess|vless)://[^\s<>"']+""", RegexOption.IGNORE_CASE)
    private val authorization =
        Regex("""\b(?:bearer|basic)\s+[a-z0-9._~+/=-]+""", RegexOption.IGNORE_CASE)
    private val sensitivePair = Regex(
        """(["']?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|authorization|proxy[_-]?authorization|api[_-]?key|apikey|subscription(?:[_-]?url)?|support[_-]?url|name|profile[_-]?(?:name|title)|currentProfileName|node[_-]?name)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)""",
        RegexOption.IGNORE_CASE,
    )
    private val sensitiveArgument = Regex(
        """(--(?:password|passwd|token|secret|authorization|api[_-]?key|subscription[_-]?url|support[_-]?url)(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s]+)""",
        RegexOption.IGNORE_CASE,
    )
    private val profileLabel = Regex(
        """(\b(?:profile|node)\s+(?:name\s+)?)(?:`[^`]*`|"[^"]*"|'[^']*')""",
        RegexOption.IGNORE_CASE,
    )
    private val rawPayload = Regex(
        """(\b(?:raw(?:[_-]?(?:config|data|payload))?|config|data|payload|params|ipc[_-]?payload|quickstart[_-]?params|profile[_-]?yaml|subscription[_-]?content)\s*[:=]\s*)(?:\{.*|\[.*|.+)$""",
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
}
