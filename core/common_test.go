package main

import (
	"context"
	"testing"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

func TestApplyRuntimeUpdateToSnapshot(t *testing.T) {
	previous := currentRuntimeRawConfig
	defer func() { currentRuntimeRawConfig = previous }()

	currentRuntimeRawConfig = map[string]any{
		"mixed-port": float64(7890),
		"tun":        map[string]any{"enable": false},
	}
	mixedPort := 0
	mode := tunnel.Global
	logLevel := log.ERROR
	stack := constant.TunMixed
	device := "flclash"
	params := &UpdateParams{
		MixedPort: &mixedPort,
		Mode:      &mode,
		LogLevel:  &logLevel,
		Tun: &tunSchema{
			Enable: true,
			Stack:  &stack,
			Device: &device,
		},
	}

	applyRuntimeUpdateToSnapshot(params)

	if actual := currentRuntimeRawConfig["mixed-port"]; actual != 0 {
		t.Fatalf("mixed-port = %v, want 0", actual)
	}
	if actual := currentRuntimeRawConfig["mode"]; actual != mode.String() {
		t.Fatalf("mode = %v, want %q", actual, mode.String())
	}
	if actual := currentRuntimeRawConfig["log-level"]; actual != logLevel.String() {
		t.Fatalf("log-level = %v, want %q", actual, logLevel.String())
	}
	tunConfig := currentRuntimeRawConfig["tun"].(map[string]any)
	if actual := tunConfig["enable"]; actual != true {
		t.Fatalf("tun.enable = %v, want true", actual)
	}
	if actual := tunConfig["stack"]; actual != stack.String() {
		t.Fatalf("tun.stack = %v, want %q", actual, stack.String())
	}
}

func TestTunnelHTTPRequestRejectsMissingURL(t *testing.T) {
	_, err := handleTunnelHTTPRequest(`{"method":"GET"}`)
	if err == nil {
		t.Fatal("expected an empty URL to be rejected")
	}
}

func TestCancelTunnelHTTPRequest(t *testing.T) {
	const requestID = "test-request"
	ctx, cancel := context.WithCancel(context.Background())
	tunnelHTTPRequests.Store(requestID, cancel)
	defer tunnelHTTPRequests.Delete(requestID)

	if !cancelTunnelHTTPRequest(requestID) {
		t.Fatal("expected registered request to be cancelled")
	}
	if ctx.Err() != context.Canceled {
		t.Fatalf("context error = %v, want context.Canceled", ctx.Err())
	}
	if cancelTunnelHTTPRequest("") {
		t.Fatal("empty request ID must not cancel a request")
	}
}
