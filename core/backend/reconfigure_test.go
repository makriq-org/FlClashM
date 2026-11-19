package backend

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

type liveHostEngine struct{ hostEngine }

type selectionHostEngine struct{ hostEngine }

func (h selectionHostEngine) ApplySelection(ctx context.Context, _, next *RuntimePlan) error {
	if err := h.step(ctx, "engine.selection"); err != nil {
		return err
	}
	h.mu.Lock()
	h.applied = next.Payload()
	h.mu.Unlock()
	return nil
}

func TestRecoveryInstallsAbsentRuntimeWithLiveAdapters(t *testing.T) {
	for name, adapter := range map[string]func(*host) EngineAdapter{
		"selection":     func(h *host) EngineAdapter { return selectionHostEngine{hostEngine{h}} },
		"live-settings": func(h *host) EngineAdapter { return liveHostEngine{hostEngine{h}} },
	} {
		for _, reopen := range []bool{false, true} {
			mode := "resource-loss"
			if reopen {
				mode = "new-process"
			}
			t.Run(name+"/"+mode, func(t *testing.T) {
				store := newStore(t)
				h := newHost()
				open := func() *Backend {
					b, err := Open(store, h, adapter(h), hostTransports{h}, hostPlatform{h})
					if err != nil {
						t.Fatal(err)
					}
					return b
				}
				b := open()
				run(t, b, "connect", "connect", `{"config":{"mode":"rule"},"patch":{"mode":"rule"},"nodes":[]}`)
				generation := b.Snapshot().AppliedGeneration
				if reopen {
					if err := b.Close(); err != nil {
						t.Fatal(err)
					}
					h = newHost()
					b = open()
				} else {
					h.mu.Lock()
					h.states = map[string]bool{}
					h.applied = nil
					h.mu.Unlock()
				}
				defer b.Close()
				run(t, b, "recover", "recover", "")
				if snapshot := b.Snapshot(); snapshot.Observed.State != "running" || snapshot.AppliedGeneration <= generation {
					t.Fatal("recovery did not commit a newly installed plan", snapshot)
				}
			})
		}
	}
}

func (h liveHostEngine) ApplyLiveSettings(ctx context.Context, _, next *RuntimePlan) error {
	if err := h.step(ctx, "engine.live"); err != nil {
		return err
	}
	h.mu.Lock()
	h.applied = next.Payload()
	h.mu.Unlock()
	return nil
}

type proxyOnlyHostPlatform struct{ hostPlatform }

func (h proxyOnlyHostPlatform) Start(ctx context.Context, plan *RuntimePlan) error {
	if strings.Contains(string(plan.Payload()), `"mixed-port":0`) {
		return ErrNoIngress
	}
	return h.hostPlatform.Start(ctx, plan)
}

type proxyOnlyLiveEngine struct{ liveHostEngine }

func (h proxyOnlyLiveEngine) ApplyLiveSettings(ctx context.Context, old, next *RuntimePlan) error {
	if err := h.liveHostEngine.ApplyLiveSettings(ctx, old, next); err != nil {
		return err
	}
	if strings.Contains(string(next.Payload()), `"mixed-port":0`) {
		return ErrNoIngress
	}
	return nil
}

func TestApplyingDisabledLastProxyPortStopsRuntime(t *testing.T) {
	const enabled = `{"config":{"mixed-port":7890},"patch":{"mixed-port":7890}}`
	const disabled = `{"config":{"mixed-port":0},"patch":{"mixed-port":0}}`
	for name, adapter := range map[string]func(*host) EngineAdapter{
		"reinstall": func(h *host) EngineAdapter { return hostEngine{h} },
		"live":      func(h *host) EngineAdapter { return proxyOnlyLiveEngine{liveHostEngine{hostEngine{h}}} },
	} {
		t.Run(name, func(t *testing.T) {
			h := newHost()
			b, err := Open(newStore(t), h, adapter(h), hostTransports{h}, proxyOnlyHostPlatform{hostPlatform{h}})
			if err != nil {
				t.Fatal(err)
			}
			defer b.Close()
			run(t, b, "enable", "connect", enabled)
			disabledReceipt := run(t, b, "disable", "apply", disabled)
			if snapshot := b.Snapshot(); snapshot.DesiredRunning || snapshot.AppliedRunning ||
				snapshot.Observed.State != "stopped" || snapshot.AppliedGeneration != disabledReceipt.Generation {
				t.Fatal("disabling the port did not commit a stopped runtime", snapshot)
			}
			expectFailure(t, b, "no-ingress-start", "connect", disabled)
			plan, _, err := b.Applied()
			if err != nil || plan == nil || string(plan.Payload()) != disabled || b.Snapshot().AppliedRunning {
				t.Fatal("failed start did not preserve the disabled port", err, b.Snapshot())
			}
		})
	}
}

func TestLiveSettingsKeepVPNAndRebuildBakedPlatformOptions(t *testing.T) {
	for _, systemProxy := range []bool{false, true} {
		t.Run(map[bool]string{false: "without-system-proxy", true: "with-system-proxy"}[systemProxy], func(t *testing.T) {
			h := newHost()
			b, err := Open(newStore(t), h, liveHostEngine{hostEngine{h}}, hostTransports{h}, hostPlatform{h})
			if err != nil {
				t.Fatal(err)
			}
			defer b.Close()
			payload := map[string]any{"config": map[string]any{"mode": "rule", "mixed-port": 7890, "dns": map[string]any{"enable": true}}, "patch": map[string]any{"mode": "rule", "mixed-port": 7890}, "coreState": map[string]any{"vpn-props": map[string]any{"systemProxy": systemProxy}}, "nodes": []any{}}
			run := func(id, method string) {
				t.Helper()
				raw, _ := json.Marshal(payload)
				if _, err := b.Submit(Request{APIVersion: 1, OperationID: id, Method: method, Input: Input(raw)}); err != nil {
					t.Fatal(err)
				}
				if _, err := b.Await(context.Background(), id); err != nil {
					t.Fatal(err)
				}
			}
			count := func(name string) int {
				h.mu.Lock()
				defer h.mu.Unlock()
				total := 0
				for _, call := range h.calls {
					if call == name {
						total++
					}
				}
				return total
			}
			run("connect", "connect")
			startedAt := b.Snapshot().StartedAt
			starts := count("platform.start")
			payload["config"].(map[string]any)["mode"] = "direct"
			payload["patch"].(map[string]any)["mode"] = "direct"
			run("mode", "apply")
			if count("engine.live") != 1 || count("platform.start") != starts || b.Snapshot().StartedAt != startedAt {
				t.Fatal("mode switch replaced VPN")
			}
			payload["config"].(map[string]any)["mixed-port"] = 7891
			payload["patch"].(map[string]any)["mixed-port"] = 7891
			run("port", "apply")
			expected := starts
			if systemProxy {
				expected++
			}
			if count("platform.start") != expected {
				t.Fatal("system proxy endpoint lifecycle was not preserved")
			}
			payload["config"].(map[string]any)["dns"] = map[string]any{"enable": false}
			run("dns", "apply")
			if count("platform.start") != expected+1 {
				t.Fatal("DNS configuration bypassed full application")
			}
			plan, _, err := b.Applied()
			if err != nil || !strings.Contains(string(plan.Payload()), `"mode":"direct"`) {
				t.Fatal("live change was not committed", err)
			}
		})
	}
}

func TestPlanDigestSortsTopLevelAndKeepsNestedOrder(t *testing.T) {
	type prepared struct {
		Config   json.RawMessage   `json:"config"`
		Selected map[string]string `json:"selected-map"`
	}
	config := json.RawMessage(`{"dns":{"nameserver-policy":{"z.example":"1.1.1.1","a.example":"8.8.8.8"}}}`)
	fromStruct, err := NewRuntimePlan(1, prepared{config, map[string]string{"g": "p"}})
	if err != nil {
		t.Fatal(err)
	}
	fromMap, err := NewRuntimePlan(1, map[string]json.RawMessage{"selected-map": json.RawMessage(`{"g":"p"}`), "config": config})
	if err != nil {
		t.Fatal(err)
	}
	if fromStruct.Digest() != fromMap.Digest() {
		t.Fatalf("digest depends on top-level order: %s vs %s", fromStruct.Payload(), fromMap.Payload())
	}
	if payload := string(fromStruct.Payload()); strings.Index(payload, "z.example") > strings.Index(payload, "a.example") {
		t.Fatalf("nested order lost: %s", payload)
	}
	if _, err := NewRuntimePlan(1, json.RawMessage(`null`)); err == nil {
		t.Fatal("null payload accepted")
	}
}
