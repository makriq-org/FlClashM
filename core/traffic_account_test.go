package main

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/proxydialer"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// The TUN listener asserts provider.Tunnel unchecked; the wrapper must offer it.
func TestTrafficTunnelOffersEveryInterfaceMihomoAsserts(t *testing.T) {
	if _, ok := trafficTunnel.(provider.Tunnel); !ok {
		t.Fatal("trafficTunnel does not satisfy provider.Tunnel; TUN start panics")
	}
	if _, ok := trafficTunnel.(proxydialer.Tunnel); !ok {
		t.Fatal("trafficTunnel does not satisfy proxydialer.Tunnel")
	}
	rp := trafficTunnel.(provider.Tunnel)
	if rp.RuleUpdateCallback() != tunnel.Tunnel.RuleUpdateCallback() {
		t.Fatal("rule update callback must be mihomo's own, not a fresh one")
	}
}

func registerTracker(t *testing.T, metadata *constant.Metadata) statistic.Tracker {
	t.Helper()
	local, remote := net.Pipe()
	go func() { _, _ = io.Copy(io.Discard, remote) }()
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})
	tracker := statistic.NewTCPTracker(
		outbound.NewConn(local, direct),
		statistic.DefaultManager,
		metadata,
		nil,
		0,
		0,
		true,
	)
	t.Cleanup(func() {
		_ = tracker.Close()
		_ = remote.Close()
	})
	return tracker
}

func TestTrafficAccountKeepsLookingForATrackerRegisteredAfterTheBurst(t *testing.T) {
	metadata := &constant.Metadata{}
	account := trafficAccount{metadata: metadata}
	for packet := 0; packet <= routeLookupBurst; packet++ {
		account.add(1, 0)
	}
	if account.route != routeUnknown || account.up != routeLookupBurst+1 {
		t.Fatalf("before the tracker: route %d, waiting %d bytes", account.route, account.up)
	}

	tracker := registerTracker(t, metadata)
	account.lookedUp = time.Now().Add(time.Hour)
	account.add(1, 0)
	if account.route != routeUnknown {
		t.Fatal("looked the tracker up again inside the gap")
	}

	account.lookedUp = time.Now().Add(-routeLookupGap)
	account.add(1, 0)
	if account.route != routeDirect || account.trackerID != tracker.ID() {
		t.Fatalf("after the gap: route %d, tracker %q; want direct and %q", account.route, account.trackerID, tracker.ID())
	}
	if account.up != 0 {
		t.Fatalf("%d bytes still waiting after the session was attributed", account.up)
	}
}

func TestTrafficClassificationDoesNotWaitForConfigurationLock(t *testing.T) {
	previous := activeTrafficProxies.Load()
	t.Cleanup(func() { activeTrafficProxies.Store(previous) })
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "bypass"})
	publishTrafficProxies(map[string]constant.Proxy{"bypass": adapter.NewProxy(direct)}, nil)
	captured := activeTrafficProxies.Load()
	publishTrafficProxies(nil, nil)
	runLock.Lock()
	done := make(chan bool, 1)
	go func() { done <- captured.isDirect(constant.Chain{"bypass"}) }()
	select {
	case direct := <-done:
		runLock.Unlock()
		if !direct {
			t.Fatal("captured direct alias changed with replacement config")
		}
	case <-time.After(time.Second):
		runLock.Unlock()
		t.Fatal("traffic accounting waited for configuration lock")
	}
}
