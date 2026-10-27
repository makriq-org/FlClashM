package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"core/backend/compile"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
)

func TestHTTPStatusRejectionIsNotReportedAsTimeout(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Millisecond)
		if r.URL.Path == "/" {
			w.Header().Set("Location", "/ok")
			w.WriteHeader(http.StatusFound)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	proxy := namedProxy("status-test")
	expected, _ := utils.NewUnsignedRanges[uint16]("200")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if delay, err := proxy.URLTest(ctx, server.URL, expected); err != nil || delay == 0 {
		t.Fatal("redirect did not answer the HTTP request", delay, err)
	}
	failed := proxy.ExtraDelayHistories()[server.URL]
	if failed.Alive {
		t.Fatal("expected-status:200 unexpectedly accepted a redirect")
	}
	latest := failed.History[len(failed.History)-1]
	if got := healthCheckDelayValue(latest, proxy.DelayHistory()); got != -2 {
		t.Fatal("a received HTTP response was shown as a timeout", got)
	}
	// The final URL answers 200 with the same node and status requirement.
	if _, err := proxy.URLTest(ctx, server.URL+"/ok", expected); err != nil {
		t.Fatal(err)
	}
	success := proxy.ExtraDelayHistories()[server.URL+"/ok"]
	if !success.Alive || healthCheckDelayValue(success.History[len(success.History)-1], proxy.DelayHistory()) <= 0 {
		t.Fatal("the final URL was not reported as healthy")
	}
	// An unrelated successful probe must not disguise a network failure.
	server.Close()
	_, _ = proxy.URLTest(ctx, server.URL+"/closed", expected)
	unreachable := proxy.ExtraDelayHistories()[server.URL+"/closed"]
	if got := healthCheckDelayValue(unreachable.History[len(unreachable.History)-1], proxy.DelayHistory()); got != -1 {
		t.Fatal("unrelated success replaced the failed network measurement", got)
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
				Text: "dns: {enable: true, nameserver: ['127.0.0.1']}\n" +
					"proxies: [{name: dead, type: reject}, {name: healthy, type: direct}]\n" +
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

func TestProviderIntervalIsIncludedOnlyForActiveChecks(t *testing.T) {
	previous := minHealthCheckInterval
	t.Cleanup(func() { minHealthCheckInterval = previous })
	for _, test := range []struct {
		name, check string
		want        time.Duration
	}{
		{"enabled", "{enable: true, url: 'https://example.test/check', interval: 5}", 5 * time.Second},
		{"disabled", "{enable: false, url: 'https://example.test/check', interval: 1}", 100 * time.Second},
		{"not enabled", "{url: 'https://example.test/check', interval: 1}", 100 * time.Second},
		{"empty URL", "{enable: true, url: '', interval: 1}", 100 * time.Second},
		{"blank URL", "{enable: true, url: '  ', interval: 1}", 100 * time.Second},
	} {
		t.Run(test.name, func(t *testing.T) {
			raw, err := config.UnmarshalRawConfig([]byte("proxy-groups: [{name: Auto, type: fallback, interval: 100}]\nproxy-providers: {nodes: {health-check: " + test.check + "}}"))
			if err != nil {
				t.Fatal(err)
			}
			computeMinHealthCheckInterval(raw)
			if minHealthCheckInterval != test.want {
				t.Fatalf("touch interval = %v, want %v", minHealthCheckInterval, test.want)
			}
		})
	}
}
