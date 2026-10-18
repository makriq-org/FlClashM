package backend

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"
)

type policyHostEngine struct{ commandHostEngine }

func (h policyHostEngine) SystemDNS(ctx context.Context, values []string) error {
	return h.step(ctx, "dns."+values[0])
}
func (h policyHostEngine) ResetNetwork(ctx context.Context) error {
	return h.step(ctx, "network.reset")
}
func (h policyHostEngine) ScreenActive(ctx context.Context, value bool) error {
	return h.step(ctx, "screen."+strconv.FormatBool(value))
}
func (h policyHostEngine) Awake(ctx context.Context, value bool) error {
	return h.step(ctx, "awake."+strconv.FormatBool(value))
}
func (h policyHostEngine) ProbeHealth(ctx context.Context) (bool, error) {
	return true, h.step(ctx, "health.probe")
}

func TestPlatformPolicyRetainsHeadlessScreenAndNetworkBehavior(t *testing.T) {
	h := newHost()
	nodes := newNodeHost()
	b, err := Open(newStore(t), h, policyHostEngine{commandHostEngine{hostEngine{h}}}, nil, hostPlatform{h}, NodeOptions{Adapter: nodes, Inspection: nodes, Cache: nodes, ABI: "host", Now: nodes.now, ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	run := func(id, method string, input Input) {
		t.Helper()
		if _, err := b.Submit(Request{APIVersion: 1, OperationID: id, Method: method, Input: input}); err != nil {
			t.Fatal(err)
		}
		if _, err := b.Await(context.Background(), id); err != nil {
			t.Fatal(err)
		}
	}
	command := func(id string, event *PlatformEvent) {
		t.Helper()
		method := "platform.tick"
		var params json.RawMessage
		if event != nil {
			method = "platform.event"
			params, _ = json.Marshal(event)
		}
		if _, err := b.SubmitEngineCommand(id, EngineCommand{Method: method, Params: params}); err != nil {
			t.Fatal(err)
		}
		if _, err := b.Await(context.Background(), id); err != nil {
			t.Fatal(err)
		}
	}
	count := func(name string) int {
		h.mu.Lock()
		defer h.mu.Unlock()
		result := 0
		for _, call := range h.calls {
			if call == name {
				result++
			}
		}
		return result
	}
	run("connect", "connect", Input(`{"nodes":[]}`))
	command("network1", &PlatformEvent{Sequence: 2, Kind: "network", Available: true, Validated: true, DNS: []string{"1.1.1.1"}, Scope: "wifi"})
	command("same-network", &PlatformEvent{Sequence: 3, Kind: "network", Available: true, Validated: true, DNS: []string{"1.1.1.1"}, Scope: "wifi"})
	command("old-network", &PlatformEvent{Sequence: 1, Kind: "network", Available: true, DNS: []string{"8.8.8.8"}, Scope: "old"})
	if count("network.reset") != 1 || count("health.probe") != 1 || count("dns.8.8.8.8") != 0 {
		t.Fatal("network burst or obsolete observation triggered work")
	}
	command("dark", &PlatformEvent{Sequence: 4, Kind: "screen", ScreenOn: false})
	nodes.advance(121 * time.Second)
	command("grace-expired", nil)
	if count("awake.false") != 1 {
		t.Fatal("screen-off grace did not release wake lock")
	}
	nodes.advance(16 * time.Minute)
	command("sleeping-watchdog", nil)
	if count("health.probe") != 1 {
		t.Fatal("standby woke the radio")
	}
	command("screen-on", &PlatformEvent{Sequence: 5, Kind: "screen", ScreenOn: true})
	if count("health.probe") != 2 {
		t.Fatal("screen-on did not catch up a missed health check")
	}
	command("doze", &PlatformEvent{Sequence: 6, Kind: "screen", ScreenOn: true, Dozing: true})
	if count("awake.false") != 2 {
		t.Fatal("Doze did not release wake lock immediately")
	}
	run("stop", "stop", nil)
	before := count("network.reset")
	command("stopped-network", &PlatformEvent{Sequence: 7, Kind: "network", Available: true, Validated: true, DNS: []string{"9.9.9.9"}, Scope: "cellular"})
	if count("network.reset") != before || b.Snapshot().DesiredRunning {
		t.Fatal("OS event resurrected stopped runtime")
	}
	run("resume-in-doze", "start", nil)
	if count("awake.false") != 3 {
		t.Fatal("normal start ignored retained Doze observation")
	}
}

// The host reports facts only. A late service teardown cannot override a new
// user stop; permission loss durably stops instead of looping recovery.
type permissionPlatform struct {
	hostPlatform
	allowed bool
}

func (p permissionPlatform) VPNPermission(context.Context) (bool, error) { return p.allowed, nil }
func TestServiceLossAndRevocationUseCommonRecoveryAndRespectStop(t *testing.T) {
	h := newHost()
	platform := permissionPlatform{hostPlatform{h}, false}
	b, err := Open(newStore(t), h, policyHostEngine{commandHostEngine{hostEngine{h}}}, hostTransports{h}, platform)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	run(t, b, "start", "connect", `{"nodes":[]}`)
	h.mu.Lock()
	h.states["platform"] = false
	h.mu.Unlock()
	if err = b.coordinator.platformLost(context.Background(), b, "lost-service", false); err != nil {
		t.Fatal(err)
	}
	if b.Snapshot().Observed.State != "running" {
		t.Fatal("service loss did not rebuild committed plan")
	}
	h.mu.Lock()
	h.states["platform"] = false
	h.mu.Unlock()
	if err = b.coordinator.platformLost(context.Background(), b, "revoked", true); err != nil {
		t.Fatal(err)
	}
	if b.Snapshot().DesiredRunning || b.Snapshot().Observed.State != "stopped" {
		t.Fatal("permission loss did not persist stop")
	}
	generation := b.Snapshot().Generation
	if err = b.coordinator.platformLost(context.Background(), b, "late-destroy", false); err != nil {
		t.Fatal(err)
	}
	if b.Snapshot().Generation != generation {
		t.Fatal("late destruction resurrected stopped runtime")
	}
}
