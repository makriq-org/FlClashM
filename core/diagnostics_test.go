package main

import (
	"strings"
	"testing"
)

func TestRedactDiagnosticMessage(t *testing.T) {
	input := strings.Join([]string{
		`password: "hunter2" token=abc123`,
		`Authorization: Bearer very-secret-token`,
		`subscription_url=https://user:pass@example.com/sub/secret?token=abc`,
		"profile `My private profile` failed",
		`raw config={"proxies":[{"password":"hidden"}]}`,
		`name: "Node from JSON"`,
		"ipc payload={\n  \"password\": \"second-line-secret\"\n}",
	}, "\n")

	redacted := redactDiagnosticMessage(input)
	for _, secret := range []string{
		"hunter2",
		"abc123",
		"very-secret-token",
		"user:pass",
		"/sub/secret",
		"My private profile",
		"Node from JSON",
		`"proxies"`,
		"hidden",
		"second-line-secret",
	} {
		if strings.Contains(redacted, secret) {
			t.Fatalf("redacted output leaked %q: %s", secret, redacted)
		}
	}
}
