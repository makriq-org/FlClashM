package main

import (
	"regexp"
)

const (
	diagnosticReplacement    = "<redacted>"
	diagnosticURLReplacement = "<redacted-url>"
)

var (
	diagnosticURL = regexp.MustCompile(
		`(?i)(?:https?|socks5?|ss|trojan|vmess|vless)://[^\s<>"']+`,
	)
	diagnosticAuthorization = regexp.MustCompile(
		`(?i)\b(?:bearer|basic)\s+[a-z0-9._~+/=-]+`,
	)
	diagnosticSensitivePair = regexp.MustCompile(
		`(?i)(["']?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|authorization|proxy[_-]?authorization|api[_-]?key|apikey|subscription(?:[_-]?url)?|support[_-]?url|name|profile[_-]?(?:name|title)|currentProfileName|node[_-]?name)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)`,
	)
	diagnosticSensitiveArgument = regexp.MustCompile(
		`(?i)(--(?:password|passwd|token|secret|authorization|api[_-]?key|subscription[_-]?url|support[_-]?url)(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s]+)`,
	)
	diagnosticProfileLabel = regexp.MustCompile(
		`(?i)(\b(?:profile|node)\s+(?:name\s+)?)(?:` + "`[^`]*`" + `|"[^"]*"|'[^']*')`,
	)
	diagnosticRawPayload = regexp.MustCompile(
		`(?is)(\b(?:raw(?:[_-]?(?:config|data|payload))?|config|data|payload|params|ipc[_-]?payload|quickstart[_-]?params|profile[_-]?yaml|subscription[_-]?content)\s*[:=]\s*)(?:\{.*|\[.*|.+)$`,
	)
)

func redactDiagnosticMessage(value string) string {
	if value == "" {
		return value
	}
	value = diagnosticURL.ReplaceAllString(value, diagnosticURLReplacement)
	value = diagnosticAuthorization.ReplaceAllString(value, diagnosticReplacement)
	value = diagnosticSensitivePair.ReplaceAllString(value, `${1}`+diagnosticReplacement)
	value = diagnosticSensitiveArgument.ReplaceAllString(value, `${1}`+diagnosticReplacement)
	value = diagnosticProfileLabel.ReplaceAllString(value, `${1}`+diagnosticReplacement)
	return diagnosticRawPayload.ReplaceAllString(
		value,
		`${1}`+diagnosticReplacement,
	)
}
