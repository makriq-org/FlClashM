package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"core/backend"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

type gatedAdapter struct {
	constant.ProxyAdapter
	gate func(ctx context.Context) error
}

func (a gatedAdapter) DialContext(ctx context.Context, metadata *constant.Metadata) (constant.Conn, error) {
	if err := a.gate(ctx); err != nil {
		return nil, err
	}
	return a.ProxyAdapter.DialContext(ctx, metadata)
}

func gatedProxy(name string, gate func(ctx context.Context) error) constant.Proxy {
	return adapter.NewProxy(gatedAdapter{outbound.NewDirectWithOption(outbound.DirectOption{Name: name}), gate})
}

func lagging(lag time.Duration) func(ctx context.Context) error {
	return func(ctx context.Context) error {
		select {
		case <-time.After(lag):
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func laggingProxy(name string, lag time.Duration) constant.Proxy {
	return gatedProxy(name, lagging(lag))
}

func noContentAfterAMillisecond(w http.ResponseWriter, _ *http.Request) {
	time.Sleep(time.Millisecond)
	w.WriteHeader(http.StatusNoContent)
}

func balanceOver(t *testing.T, name string, members ...constant.Proxy) constant.Proxy {
	t.Helper()
	health := provider.NewHealthCheck(members, "", 0, 0, true, nil)
	pd, err := provider.NewCompatibleProvider(name+"-provider", members, health)
	if err != nil {
		t.Fatalf("NewCompatibleProvider: %v", err)
	}
	group, err := outboundgroup.NewLoadBalance(
		outboundgroup.GroupCommonOption{Name: name},
		outboundgroup.LoadBalanceOption{Strategy: "round-robin"},
		namedProxy("COMPATIBLE"),
		[]cp.ProxyProvider{pd},
	)
	if err != nil {
		t.Fatalf("NewLoadBalance: %v", err)
	}
	return adapter.NewProxy(group)
}

func selectorOver(t *testing.T, name string, members ...constant.Proxy) constant.Proxy {
	t.Helper()
	pd, err := provider.NewCompatibleProvider(name+"-provider", members, provider.NewHealthCheck(members, "", 0, 0, true, nil))
	if err != nil {
		t.Fatalf("NewCompatibleProvider: %v", err)
	}
	group, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{Name: name},
		outboundgroup.SelectorOption{},
		namedProxy("COMPATIBLE"),
		[]cp.ProxyProvider{pd},
	)
	if err != nil {
		t.Fatalf("NewSelector: %v", err)
	}
	return adapter.NewProxy(group)
}

// testBalancer installs one group as the applied proxy set, so the delay test
// resolves it by name exactly as the UI asks.
func testBalancer(t *testing.T, proxies map[string]constant.Proxy) {
	t.Helper()
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	setProbeProxies(proxies)
	t.Cleanup(func() {
		runLock.Lock()
		tunnel.UpdateProxies(previousProxies, previousProviders)
		runLock.Unlock()
		// Probes still running once the balancer answered hold slots the next
		// test counts.
		for deadline := time.Now().Add(5 * time.Second); heldDelaySlots() > 0; time.Sleep(10 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Error("member probes still hold delay test slots")
				return
			}
		}
	})
}

// stubRuntimeNodes describes the runtime nodes the delay test reads; no backend
// runs in a test.
func stubRuntimeNodes(t *testing.T, nodes ...backend.NodeSnapshot) {
	t.Helper()
	previous := runtimeNodes
	runtimeNodes = func() []backend.NodeSnapshot { return nodes }
	t.Cleanup(func() { runtimeNodes = previous })
}

func delayOf(t *testing.T, name, url string, timeout int64) *Delay {
	t.Helper()
	done := make(chan *Delay, 1)
	go func() {
		done <- testDelayNow(TestDelayParams{ProxyName: name, TestUrl: url, Timeout: timeout})
	}()
	select {
	case result := <-done:
		return result
	case <-time.After(10 * time.Second):
		t.Fatal("delay test did not answer")
		return nil
	}
}

// testDelayNow mirrors the callback path of handleAsyncTestDelay, which cannot
// return a value: an empty answer is the "never got a slot" case.
func testDelayNow(params TestDelayParams) *Delay {
	raw, _ := json.Marshal(params)
	answer := make(chan string, 1)
	handleAsyncTestDelay(string(raw), func(value string) { answer <- value })
	value := <-answer
	if value == "" {
		return nil
	}
	var delay Delay
	if json.Unmarshal([]byte(value), &delay) != nil {
		return nil
	}
	return &delay
}

// heldDelaySlots counts the slots member probes are holding right now.
func heldDelaySlots() int {
	held := 0
	for testDelaySem.TryAcquire(1) {
		held++
	}
	if held > 0 {
		testDelaySem.Release(int64(held))
	}
	return 50 - held
}

func TestABalancerAnswersWhileTheMemberItWouldPickIsDown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	balance := balanceOver(t, "Balance", laggingProxy("down", time.Hour), namedProxy("up"))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	start := time.Now()
	delay := delayOf(t, "Balance", server.URL, 2000)

	if delay == nil || delay.Value <= 0 {
		t.Fatalf("delay = %+v, want the live member's", delay)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("answered after %v, want it not waiting out the member that is down", elapsed)
	}
}

func TestABalancerAnswerLeavesItsSlowerMembersAlive(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	dialing := make(chan struct{})
	slow := gatedProxy("slow", func(ctx context.Context) error {
		close(dialing)
		return lagging(200 * time.Millisecond)(ctx)
	})
	fast := gatedProxy("fast", func(context.Context) error {
		<-dialing
		return nil
	})
	balance := balanceOver(t, "Balance", fast, slow)
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	if delay := delayOf(t, "Balance", server.URL, 3000); delay == nil || delay.Value <= 0 {
		t.Fatalf("delay = %+v, want the fast member's", delay)
	}

	for wait := time.Now().Add(2 * time.Second); len(slow.DelayHistory()) == 0; {
		if time.Now().After(wait) {
			t.Fatal("the slower member never finished its test")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !slow.AliveForTestUrl(server.URL) {
		t.Error("the slower member was recorded as dead once the balancer had its answer")
	}
}

func TestABalancerWithEveryMemberDownTimesOut(t *testing.T) {
	balance := balanceOver(t, "Balance", laggingProxy("a", time.Hour), laggingProxy("b", time.Hour))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	delay := delayOf(t, "Balance", "http://127.0.0.1:1", 200)

	if delay == nil || delay.Value != delayTimedOut {
		t.Errorf("delay = %+v, want value %d", delay, delayTimedOut)
	}
}

func TestABalancerBehindASelectorAnswersWhileOneOfItsMembersIsDown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	inner := balanceOver(t, "Inner", laggingProxy("down", time.Hour), namedProxy("up"))
	pick := selectorOver(t, "Pick", inner)
	balance := balanceOver(t, "Balance", pick)
	testBalancer(t, map[string]constant.Proxy{"Balance": balance, "Pick": pick})

	delay := delayOf(t, "Balance", server.URL, 2000)

	if delay == nil || delay.Value <= 0 {
		t.Errorf("delay = %+v, want the live member's under the selector's pick", delay)
	}
}

func TestABalancerMemberProbesEachTakeADelayTestSlot(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	hold := func(ctx context.Context) error {
		entered <- struct{}{}
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	balance := balanceOver(t, "Balance", gatedProxy("a", hold), gatedProxy("b", hold))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	done := make(chan *Delay, 1)
	go func() {
		done <- testDelayNow(TestDelayParams{ProxyName: "Balance", TestUrl: server.URL, Timeout: 2000})
	}()
	for range 2 {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("both members never started probing")
		}
	}
	// Each member holds its own slot, so the group's test costs one per node.
	if held := heldDelaySlots(); held != 2 {
		t.Errorf("slots held while both members probe = %d, want 2", held)
	}
	close(release)
	<-done
}

func TestABalancerTellsSameNamedMembersApart(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	balance := balanceOver(t, "Balance", laggingProxy("node", time.Hour), namedProxy("node"))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	delay := delayOf(t, "Balance", server.URL, 2000)

	if delay == nil || delay.Value <= 0 {
		t.Errorf("delay = %+v, want the live one of two members named alike", delay)
	}
}

func TestABalancerLatticeProbesEachNodeOnce(t *testing.T) {
	probes := map[string]*atomic.Int32{}
	down := func(name string) constant.Proxy {
		probes[name] = &atomic.Int32{}
		return gatedProxy(name, func(context.Context) error {
			probes[name].Add(1)
			return errors.New("down")
		})
	}
	a, b := down("a"), down("b")
	shared := balanceOver(t, "Shared", a, b)
	balance := balanceOver(t, "Balance", balanceOver(t, "Left", shared, a), balanceOver(t, "Right", shared, b), selectorOver(t, "Pick", shared))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	if delay := delayOf(t, "Balance", "http://127.0.0.1:1", 2000); delay == nil || delay.Value != delayFailed {
		t.Fatalf("delay = %+v, want value %d", delay, delayFailed)
	}
	for name, count := range probes {
		if got := count.Load(); got != 1 {
			t.Errorf("%s probed %d times, want once however many groups reach it", name, got)
		}
	}
}

func TestABalancerAnswersWhenAMemberProbePanics(t *testing.T) {
	balance := balanceOver(t, "Balance",
		gatedProxy("panics", func(context.Context) error { panic("probe") }),
		gatedProxy("fails", func(context.Context) error { return errors.New("down") }),
	)
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})

	done := make(chan *Delay, 1)
	go func() {
		done <- testDelayNow(TestDelayParams{ProxyName: "Balance", TestUrl: "http://127.0.0.1:1", Timeout: 2000})
	}()
	select {
	case delay := <-done:
		if delay != nil {
			t.Errorf("delay = %+v, want no verdict while a member's probe never finished", delay)
		}
	case <-time.After(time.Second):
		t.Fatal("the balancer kept waiting on the member whose probe panicked")
	}
}

func TestABalancerSkipsAnExternalNodeThatIsAsleep(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	probed := &atomic.Int32{}
	asleep := gatedProxy("napping", func(context.Context) error {
		probed.Add(1)
		return errors.New("no listener while asleep")
	})
	balance := balanceOver(t, "Balance", asleep, namedProxy("up"))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})
	stubRuntimeNodes(t, backend.NodeSnapshot{Name: "napping", State: "sleeping"})

	if delay := delayOf(t, "Balance", server.URL, 2000); delay == nil || delay.Value <= 0 {
		t.Fatalf("delay = %+v, want the awake member's", delay)
	}
	// A probe of a sleeping node has no listener to reach and would record a
	// live node as dead.
	if got := probed.Load(); got != 0 {
		t.Errorf("the sleeping node was probed %d times", got)
	}
}

func TestABalancerWithOnlySleepingMembersNeverGetsASlot(t *testing.T) {
	balance := balanceOver(t, "Balance", namedProxy("a"), namedProxy("b"))
	testBalancer(t, map[string]constant.Proxy{"Balance": balance})
	stubRuntimeNodes(t,
		backend.NodeSnapshot{Name: "a", Awake: false},
		backend.NodeSnapshot{Name: "b", Awake: false},
	)

	// No node to probe means no slot was ever taken, so the UI keeps the
	// previous reading instead of showing a failure the group never had.
	if delay := delayOf(t, "Balance", "https://example.org", 2000); delay != nil {
		t.Errorf("delay = %+v, want no verdict", delay)
	}
}
