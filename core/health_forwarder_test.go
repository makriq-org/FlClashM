package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"core/backend/compile"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestSlowCompletedPingIsForwardedBeforeNextNetworkCheck(t *testing.T) {
	var requests atomic.Int32
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		time.Sleep(4 * time.Second) // Completes after the old three-second warm-up.
		w.WriteHeader(http.StatusNoContent)
	})
	proxy := namedProxy("slow-health-test")
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	runLock.Lock()
	previousConfig, previousInterval := currentConfig, minHealthCheckInterval
	previousUI := uiActive.Swap(true)
	currentConfig, minHealthCheckInterval = &config.Config{}, 300*time.Second
	tunnel.UpdateProxies(map[string]constant.Proxy{proxy.Name(): proxy}, nil)
	startHealthCheckForwarder()
	runLock.Unlock()
	t.Cleanup(func() {
		runLock.Lock()
		defer runLock.Unlock()
		stopHealthCheckForwarder()
		currentConfig, minHealthCheckInterval = previousConfig, previousInterval
		uiActive.Store(previousUI)
		tunnel.UpdateProxies(previousProxies, previousProviders)
		resetHealthCheckForwarderState()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	if _, err := proxy.URLTest(ctx, server.URL, nil); err != nil {
		t.Fatal(err)
	}
	key := proxy.Name() + "|" + server.URL
	deadline := time.Now().Add(2 * time.Second)
	for {
		healthCheckMu.Lock()
		seen := healthCheckSeen[key] != ""
		healthCheckMu.Unlock()
		if seen {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("completed ping still waits for the next 300-second probe interval")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if requests.Load() != 1 {
		t.Fatal("history polling triggered extra network probes", requests.Load())
	}
}

func TestCompiledAutomaticGroupKeepsCheckingWithoutTraffic(t *testing.T) {
	for _, kind := range []string{"fallback", "url-test", "load-balance"} {
		t.Run(kind, func(t *testing.T) {
			var requests atomic.Int32
			server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
				requests.Add(1)
				w.WriteHeader(http.StatusNoContent)
			})
			compiler := compile.Compiler{
				Capabilities: compile.Capabilities{Platform: "android"},
				Validate:     func(context.Context, compile.Object) error { return nil },
			}
			input, _ := json.Marshal(compile.Input{Version: 1, Profile: &compile.RawProfile{
				ID: "automatic",
				Text: "proxies: [{name: dead, type: reject}, {name: healthy, type: direct}]\n" +
					"proxy-groups: [{name: Auto, type: " + kind + ", proxies: [dead, healthy], lazy: false, interval: 1, url: '" + server.URL + "'}]\n" +
					"rules: ['MATCH,Auto']",
			}})
			plan, err := compiler.Compile(context.Background(), input, 1)
			if err != nil {
				t.Fatal(err)
			}
			var payload struct{ Config json.RawMessage }
			if err := json.Unmarshal(plan.Payload(), &payload); err != nil {
				t.Fatal(err)
			}
			raw, err := config.UnmarshalRawConfig(payload.Config)
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := config.ParseRawConfig(raw)
			if err != nil {
				t.Fatal(err)
			}
			for _, p := range parsed.Providers {
				t.Cleanup(func() { _ = p.(interface{ Close() error }).Close() })
			}
			p := parsed.Providers["Auto"]
			if err := p.Initial(); err != nil {
				t.Fatal(err)
			}
			// No Touch, UI, TUN or traffic: lazy:false must still run a second
			// scheduled check. The initial check alone does not catch this bug.
			deadline := time.Now().Add(4 * time.Second)
			for len(parsed.Proxies["healthy"].ExtraDelayHistories()[server.URL].History) < 2 && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if len(parsed.Proxies["healthy"].ExtraDelayHistories()[server.URL].History) < 2 || requests.Load() < 2 {
				t.Fatal("automatic probes stopped without traffic")
			}
			if kind == "fallback" || kind == "url-test" {
				group := parsed.Proxies["Auto"].Adapter().(interface{ Now() string })
				if group.Now() != "healthy" {
					t.Fatal("automatic group remained on its first dead node", group.Now())
				}
			}
		})
	}
}

func TestHealthCheckDeliveryDoesNotWaitForProbeInterval(t *testing.T) {
	for _, interval := range []time.Duration{time.Second, 100 * time.Second, 300 * time.Second} {
		if got := healthCheckForwardInterval(interval, true, true); got > time.Second || got >= interval {
			t.Fatalf("foreground results wait %s for probe interval %s", got, interval)
		}
		if got := healthCheckForwardInterval(interval, false, true); got >= interval {
			t.Fatalf("lazy providers go untouched for %s, interval %s", got, interval)
		}
	}
	if got := healthCheckForwardInterval(time.Second, false, false); got != backgroundHealthCheckInterval {
		t.Fatal("idle presentation retained foreground polling", got)
	}
}

func TestProviderIntervalIsIncludedInLazyTouchCadence(t *testing.T) {
	previous := minHealthCheckInterval
	t.Cleanup(func() { minHealthCheckInterval = previous })
	raw, err := config.UnmarshalRawConfig([]byte("proxy-groups: [{name: Auto, type: fallback, interval: 100}]\nproxy-providers: {nodes: {health-check: {enable: true, interval: 5}}}"))
	if err != nil {
		t.Fatal(err)
	}
	computeMinHealthCheckInterval(raw)
	if minHealthCheckInterval != 5*time.Second {
		t.Fatal("provider checks would go dormant", minHealthCheckInterval)
	}
}
