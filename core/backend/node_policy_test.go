package backend

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

type nodeHost struct {
	mu           sync.Mutex
	processes    map[string]NodeLaunch
	nextPort     int
	probes       int
	goodStrategy string
	groupHealthy bool
	network      bool
	selected     map[string]string
	chains       [][]string
	caches       map[string]StrategyCache
	clock        time.Time
	blockWake    bool
	wakeEntered  chan struct{}
}

func newNodeHost() *nodeHost {
	return &nodeHost{processes: map[string]NodeLaunch{}, nextPort: 40000, network: true, selected: map[string]string{"Reserve": "DIRECT"}, caches: map[string]StrategyCache{}, clock: time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)}
}
func (h *nodeHost) Prepare(ctx context.Context, _ NodePlan) error { return ctx.Err() }
func (h *nodeHost) Start(ctx context.Context, launch NodeLaunch) error {
	h.mu.Lock()
	block := h.blockWake && launch.Node.Type == "stormdns"
	entered := h.wakeEntered
	if block {
		h.blockWake = false
	}
	h.mu.Unlock()
	if block {
		close(entered)
		<-ctx.Done()
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.processes[launch.Node.ID] = launch
	return nil
}
func (h *nodeHost) Stop(ctx context.Context, id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.processes, id)
	return nil
}
func (h *nodeHost) StopAll(ctx context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.processes = map[string]NodeLaunch{}
	return nil
}
func (h *nodeHost) Observe(ctx context.Context, id string) (Observation, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	state := "stopped"
	if _, ok := h.processes[id]; ok {
		state = "running"
	}
	return Observation{State: state}, ctx.Err()
}
func (h *nodeHost) Listening(ctx context.Context, node NodePlan) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.processes[node.ID]
	return ok, ctx.Err()
}
func (h *nodeHost) AllocatePort(ctx context.Context) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextPort++
	return h.nextPort, ctx.Err()
}
func (h *nodeHost) Probe(ctx context.Context, probe NodeProbe) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.probes++
	for _, launch := range h.processes {
		if launch.Node.Port == probe.Port {
			return launch.Strategy == h.goodStrategy, ctx.Err()
		}
	}
	return false, nil
}
func (h *nodeHost) HasNetwork(ctx context.Context) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.network, ctx.Err()
}
func (h *nodeHost) TestGroup(ctx context.Context, name string, _ []string) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return name == "Storm" || h.groupHealthy, ctx.Err()
}
func (h *nodeHost) Selected(ctx context.Context, _ []string) (map[string]string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := map[string]string{}
	for k, v := range h.selected {
		out[k] = v
	}
	return out, ctx.Err()
}
func (h *nodeHost) Connections(ctx context.Context) ([][]string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.chains, ctx.Err()
}
func (h *nodeHost) NetworkScope(ctx context.Context) (string, error) { return "network-a", ctx.Err() }
func (h *nodeHost) Read(ctx context.Context, id, scope string) (StrategyCache, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.caches[id+scope], ctx.Err()
}
func (h *nodeHost) Write(ctx context.Context, id, scope string, value StrategyCache) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.caches[id+scope] = value
	return nil
}
func (h *nodeHost) now() time.Time          { h.mu.Lock(); defer h.mu.Unlock(); return h.clock }
func (h *nodeHost) advance(d time.Duration) { h.mu.Lock(); h.clock = h.clock.Add(d); h.mu.Unlock() }
func openNodeHost(t *testing.T, store Store, mechanism *nodeHost) *Backend {
	t.Helper()
	engine := newHost()
	b, err := Open(store, engine, hostEngine{engine}, nil, hostPlatform{engine}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ABI: "host", Now: mechanism.now, ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = b.Close() })
	return b
}
func reservePlan() NodePlan {
	node := NodePlan{ID: "stormdns-" + strings.Repeat("a", 32), Name: "Storm", Type: "stormdns", Host: "127.0.0.1", Port: 36200, Check: NodeCheck{Timeout: 1, StartupTimeout: 1, Requests: 1, Concurrency: 1}, Activation: &NodeActivation{Mode: "auto", ContainingGroups: []string{"Reserve"}, WatchGroup: "Reserve"}}
	node.Activation.Wake.URLs = []string{"https://example.com/check"}
	node.Activation.Wake.Interval = 30
	node.Activation.Wake.Failures = 2
	node.Activation.Wake.RetryAfter = 300
	node.Activation.Sleep.Idle = 60
	return node
}
func nodeInput(nodes ...NodePlan) string {
	raw, _ := json.Marshal(struct {
		Nodes []NodePlan `json:"nodes"`
	}{nodes})
	return string(raw)
}
func TestNodeReserveHeadlessWakeSleepAndRecovery(t *testing.T) {
	store := newStore(t)
	mechanism := newNodeHost()
	b := openNodeHost(t, store, mechanism)
	node := reservePlan()
	run(t, b, "configure", "apply", nodeInput(node))
	mechanism.mu.Lock()
	count := len(mechanism.processes)
	mechanism.mu.Unlock()
	if count != 0 {
		t.Fatal("stopped plan preparation executed processes")
	}
	run(t, b, "start", "start", "")
	events, detach := b.Subscribe(1)
	<-events
	detach()
	if err := b.ReconcileNodes(context.Background()); err != nil {
		t.Fatal(err)
	}
	mechanism.advance(30 * time.Second)
	if err := b.ReconcileNodes(context.Background()); err != nil {
		t.Fatal(err)
	}
	snapshot := b.Snapshot()
	if len(snapshot.Nodes) != 1 || !snapshot.Nodes[0].Awake || snapshot.Nodes[0].State != "running" {
		t.Fatal("headless wake", snapshot)
	}
	doc, err := store.Load()
	if err != nil || !doc.Applied.Nodes[node.ID].Awake {
		t.Fatal("awake state not committed", err)
	}
	last := doc.Receipts[len(doc.Receipts)-1]
	if !strings.HasPrefix(last.OperationID, "node-") || last.Status != "succeeded" {
		t.Fatal("node state and receipt were not committed together", last)
	}

	if err = b.Close(); err != nil {
		t.Fatal(err)
	}
	mechanism = newNodeHost()
	b = openNodeHost(t, store, mechanism)
	run(t, b, "recover", "recover", "")
	if !b.Snapshot().Nodes[0].Awake {
		t.Fatal("awake state lost on restart")
	}
	mechanism.mu.Lock()
	mechanism.selected["Reserve"] = "Storm"
	mechanism.mu.Unlock()
	mechanism.advance(2 * time.Minute)
	_ = b.ReconcileNodes(context.Background())
	mechanism.advance(2 * time.Minute)
	_ = b.ReconcileNodes(context.Background())
	if !b.Snapshot().Nodes[0].Awake {
		t.Fatal("selected reserve put to sleep")
	}
	mechanism.mu.Lock()
	mechanism.selected["Reserve"] = "DIRECT"
	mechanism.mu.Unlock()
	mechanism.advance(30 * time.Second)
	_ = b.ReconcileNodes(context.Background())
	mechanism.advance(time.Minute)
	_ = b.ReconcileNodes(context.Background())
	if b.Snapshot().Nodes[0].Awake || b.Snapshot().Nodes[0].State != "sleeping" {
		t.Fatal("idle reserve not sleeping", b.Snapshot())
	}
}
func TestNodeWakeCancelledByStop(t *testing.T) {
	mechanism := newNodeHost()
	b := openNodeHost(t, newStore(t), mechanism)
	node := reservePlan()
	node.Activation.Wake.Failures = 1
	run(t, b, "configure", "apply", nodeInput(node))
	run(t, b, "start", "start", "")
	mechanism.mu.Lock()
	mechanism.blockWake = true
	mechanism.wakeEntered = make(chan struct{})
	entered := mechanism.wakeEntered
	mechanism.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- b.ReconcileNodes(context.Background()) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("wake not started")
	}
	run(t, b, "stop", "stop", "")
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal("wake did not observe cancellation", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop blocked on wake")
	}
	mechanism.mu.Lock()
	count := len(mechanism.processes)
	mechanism.mu.Unlock()
	if count != 0 || b.Snapshot().DesiredRunning {
		t.Fatal("late wake resurrected stopped runtime")
	}
}
func TestAutoStrategyUsesVerifiedCacheAndFencesProbes(t *testing.T) {
	mechanism := newNodeHost()
	mechanism.goodStrategy = "-d1 -s2"
	b := openNodeHost(t, newStore(t), mechanism)
	options := autoOptions{Mode: "auto", Strategies: []string{"-d1 -s1", "-d1 -s2"}, Fallback: "-d1 -s3"}
	options.Test.URLs = []string{"https://example.com/check"}
	options.Test.SNI = "example.com"
	options.Test.Resolver = "system"
	options.Test.Timeout = 1
	options.Test.Requests = 1
	options.Test.Concurrency = 1
	options.Test.Ratio = 1
	options.Selection.Concurrency = 2
	options.Selection.Foreground = 2
	options.Selection.Background = true
	options.Cache.TTL = 86400
	options.Cache.Recheck = 3600
	options.Cache.Failures = 2
	options.Cache.Retry = 300
	node := NodePlan{ID: "byedpi-" + strings.Repeat("b", 32), Name: "Bye", Type: "byedpi", Host: "127.0.0.1", Port: 35600, Check: NodeCheck{StartupTimeout: 1}, Files: map[string]string{}}
	raw, _ := json.Marshal(options)
	node.Files["built-in-proxies/byedpi/"+node.ID+"/config.json"] = string(raw)
	run(t, b, "configure", "apply", nodeInput(node))
	run(t, b, "start", "start", "")
	mechanism.mu.Lock()
	launch := mechanism.processes[node.ID]
	cached := mechanism.caches[node.ID+"network-a"]
	probes := mechanism.probes
	count := len(mechanism.processes)
	mechanism.mu.Unlock()
	if launch.Strategy != mechanism.goodStrategy || !cached.Verified || probes == 0 || count != 1 {
		t.Fatal("selection/probe fence", launch.Strategy, cached, probes, count)
	}
	run(t, b, "stop", "stop", "")
	run(t, b, "restart", "start", "")
	mechanism.mu.Lock()
	newProbes := mechanism.probes
	mechanism.mu.Unlock()
	if newProbes != probes {
		t.Fatal("verified fresh cache was ignored")
	}
	if !b.Snapshot().Nodes[0].Verified {
		t.Fatal("verified strategy not projected")
	}
}

func TestInterruptedAutonomousWakeRecoversCommittedSleepingNode(t *testing.T) {
	store := newStore(t)
	mechanism := newNodeHost()
	b := openNodeHost(t, store, mechanism)
	node := reservePlan()
	node.Activation.Wake.Failures = 1
	run(t, b, "configure", "apply", nodeInput(node))
	run(t, b, "start", "start", "")
	mechanism.mu.Lock()
	mechanism.blockWake = true
	mechanism.wakeEntered = make(chan struct{})
	entered := mechanism.wakeEntered
	mechanism.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- b.ReconcileNodes(context.Background()) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("wake not entered")
	}
	doc, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if doc.Pending == nil || doc.Pending.Method != "node.wake" || doc.Pending.NodeID != node.ID {
		t.Fatal("autonomous operation was not journaled", doc.Pending)
	}
	operationID := doc.Pending.OperationID
	copyStore := newStore(t)
	if err = copyStore.Save(doc); err != nil {
		t.Fatal(err)
	}
	run(t, b, "stop", "stop", "")
	<-done
	restored := openNodeHost(t, copyStore, newNodeHost())
	receipt, err := restored.Operation(operationID)
	if err != nil || receipt.Status != "interrupted" {
		t.Fatal("interrupted node receipt", receipt, err)
	}
	run(t, restored, "recover", "recover", "")
	if restored.Snapshot().Nodes[0].Awake {
		t.Fatal("uncommitted wake replayed")
	}
}
