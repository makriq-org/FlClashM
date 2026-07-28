package main

import (
	"regexp"
	"strings"
)

const (
	diagnosticReplacement      = "<redacted>"
	diagnosticURLReplacement   = "<redacted-url>"
	maxDiagnosticMessageBytes  = 16 * 1024
	diagnosticTruncationMarker = "…<truncated>"
)

var (
	diagnosticURL = regexp.MustCompile(
		`(?i)(?:https?|socks5?|ss|trojan|vmess|vless)://[^\s<>"']+`,
	)
	diagnosticAuthorization = regexp.MustCompile(
		`(?i)\b(?:bearer|basic)\s+[a-z0-9._~+/=-]+`,
	)
	diagnosticSensitivePair = regexp.MustCompile(
		`(?i)(["']?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|auth|authorization|proxy[_-]?authorization|api[_-]?key|apikey|subscription(?:[_-]?url)?|support[_-]?url|username|user|name|profile[_-]?(?:name|title)|currentProfileName|node[_-]?name)["']?\s*[:=]\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s,;}\]]+)`,
	)
	diagnosticSensitiveArgument = regexp.MustCompile(
		`(?i)(--(?:password|passwd|token|secret|auth|authorization|api[_-]?key|subscription[_-]?url|support[_-]?url|username|user)(?:=|\s+))(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s]+)`,
	)
	diagnosticProfileLabel = regexp.MustCompile(
		`(?i)(\b(?:profile|node)\s+(?:name\s+)?)(?:` + "`[^`]*(?:`|$)" + `|"[^"]*(?:"|$)|'[^']*(?:'|$))`,
	)
	diagnosticRawPayload = regexp.MustCompile(
		`(?is)(\b(?:raw(?:[_-]?(?:config|data|payload))?|config|data|payload|params|ipc[_-]?payload|quickstart[_-]?params|profile[_-]?yaml|subscription[_-]?content)\s*[:=]\s*)(?:\{.*|\[.*|.+)$`,
	)
)

func redactDiagnosticMessage(value string) string {
	if value == "" {
		return value
	}
	var truncated bool
	value, truncated = truncateDiagnosticMessageWithStatus(value)
	value = diagnosticURL.ReplaceAllString(value, diagnosticURLReplacement)
	value = diagnosticAuthorization.ReplaceAllString(value, diagnosticReplacement)
	value = diagnosticSensitivePair.ReplaceAllString(value, `${1}`+diagnosticReplacement)
	value = diagnosticSensitiveArgument.ReplaceAllString(value, `${1}`+diagnosticReplacement)
	value = diagnosticProfileLabel.ReplaceAllString(value, `${1}`+diagnosticReplacement)
	value = diagnosticRawPayload.ReplaceAllString(
		value,
		`${1}`+diagnosticReplacement,
	)
	if !truncated {
		return truncateDiagnosticMessage(value)
	}
	if strings.HasSuffix(value, diagnosticTruncationMarker) {
		return truncateDiagnosticMessage(value)
	}
	content, _ := truncateDiagnosticMessageWithLimit(
		value,
		maxDiagnosticMessageBytes-len(diagnosticTruncationMarker),
	)
	return content + diagnosticTruncationMarker
}

func truncateDiagnosticMessage(value string) string {
	truncated, _ := truncateDiagnosticMessageWithStatus(value)
	return truncated
}

func truncateDiagnosticMessageWithStatus(value string) (string, bool) {
	if len(value) <= maxDiagnosticMessageBytes {
		return value, false
	}
	contentLimit := maxDiagnosticMessageBytes - len(diagnosticTruncationMarker)
	content, _ := truncateDiagnosticMessageWithLimit(value, contentLimit)
	return content + diagnosticTruncationMarker, true
}

func truncateDiagnosticMessageWithLimit(value string, limit int) (string, bool) {
	if len(value) <= limit {
		return value, false
	}
	end := limit
	for end > 0 && value[end]&0xc0 == 0x80 {
		end--
	}
	return value[:end], true
}
