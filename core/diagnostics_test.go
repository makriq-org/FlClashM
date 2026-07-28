package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf8"
)

type diagnosticRedactionVector struct {
	ID       string `json:"id"`
	Input    string `json:"input"`
	Expected string `json:"expected"`
}

func TestRedactDiagnosticMessageBoundsMultibyteInput(t *testing.T) {
	redacted := redactDiagnosticMessage(
		"auth=core-secret " + strings.Repeat("界", 20_000),
	)

	if len(redacted) > maxDiagnosticMessageBytes {
		t.Fatalf("message uses %d bytes", len(redacted))
	}
	if !utf8.ValidString(redacted) {
		t.Fatal("message ends on an invalid UTF-8 boundary")
	}
	if !strings.Contains(redacted, "auth="+diagnosticReplacement) {
		t.Fatal("credential was not redacted")
	}
	if !strings.HasSuffix(redacted, diagnosticTruncationMarker) {
		t.Fatal("truncation marker is missing")
	}
}

func TestRedactDiagnosticMessageRedactsQuotedSecretAtBoundary(t *testing.T) {
	redacted := redactDiagnosticMessage(
		`password="` + strings.Repeat("private phrase ", 2_000) + `"`,
	)

	expected := "password=" + diagnosticReplacement + diagnosticTruncationMarker
	if redacted != expected {
		t.Fatalf("unexpected bounded redaction:\nwant: %s\n got: %s", expected, redacted)
	}
}

func TestRedactDiagnosticMessage(t *testing.T) {
	data, err := os.ReadFile(
		"../lib/product/diagnostics/diagnostic_redaction_vectors.json",
	)
	if err != nil {
		t.Fatal(err)
	}
	var vectors []diagnosticRedactionVector
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, vector := range vectors {
		t.Run(vector.ID, func(t *testing.T) {
			if redacted := redactDiagnosticMessage(vector.Input); redacted != vector.Expected {
				t.Fatalf("unexpected redaction:\nwant: %s\n got: %s", vector.Expected, redacted)
			}
		})
	}
}
