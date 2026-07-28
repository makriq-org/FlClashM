//go:build android && cgo

package main

import (
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/log"
)

var diagnosticLogOnce sync.Once

func startDiagnosticLog() {
	diagnosticLogOnce.Do(func() {
		subscription := log.Subscribe()
		go func() {
			for event := range subscription {
				alwaysKeep := event.LogLevel >= log.WARNING &&
					event.LogLevel < log.SILENT
				if event.LogLevel < log.Level() && !alwaysKeep {
					continue
				}
				if strings.Contains(event.Payload, "http: Server closed") {
					continue
				}
				payload := redactDiagnosticMessage(event.Payload)
				_, _ = fmt.Fprintf(
					os.Stderr,
					"[mihomo][%v] %s\n",
					event.LogLevel,
					payload,
				)
			}
		}()
	})
}
