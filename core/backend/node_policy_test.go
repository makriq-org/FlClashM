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
	starts       int
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
	h.starts++
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

func TestUIWarmNodesWithoutVPNAndConnectReusesProcesses(t *testing.T) {
	store := newStore(t)
	mechanism := newNodeHost()
	b := openNodeHost(t, store, mechanism)
	node := reservePlan()
	node.Activation = nil
	input := nodeInput(node)
	run(t, b, "configure", "apply", input)
	run(t, b, "ui-warm", "warm", input)
	if s := b.Snapshot(); s.DesiredRunning || s.AppliedRunning || s.Observed.State != "stopped" || s.Nodes[0].State != "running" {
		t.Fatal("UI preparation changed VPN intent or failed to launch node", s)
	}
	run(t, b, "connect", "connect", input)
	mechanism.mu.Lock()
	starts := mechanism.starts
	mechanism.mu.Unlock()
	if starts != 1 || b.Snapshot().Observed.State != "running" {
		t.Fatal("connect restarted prepared node", starts, b.Snapshot())
	}
	run(t, b, "stop", "stop", "")
	mechanism.mu.Lock()
	left := len(mechanism.processes)
	mechanism.mu.Unlock()
	if left != 1 || b.Snapshot().DesiredRunning || b.Snapshot().AppliedRunning {
		t.Fatal("Stop lost latency preparation or retained VPN intent")
	}
	run(t, b, "recover-stopped", "recover", "")
	mechanism.mu.Lock()
	left = len(mechanism.processes)
	mechanism.mu.Unlock()
	if left != 0 || b.Snapshot().DesiredRunning {
		t.Fatal("headless recovery replayed UI preparation")
	}
}

func TestUISettingsCompleteMissingNodePreparation(t *testing.T) {
	h := newHost()
	mechanism := newNodeHost()
	b, err := Open(newStore(t), h, liveHostEngine{hostEngine{h}}, nil, hostPlatform{h}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	node := reservePlan()
	node.Activation = nil
	payload := map[string]any{"nodes": []NodePlan{node}, "config": map[string]string{"mode": "rule"}, "patch": map[string]string{"mode": "rule"}}
	input, _ := json.Marshal(payload)
	run(t, b, "configure", "apply", string(input))
	// UI attached, but preparation has not completed (or was superseded).
	if err = b.PrepareForUI(); err != nil {
		t.Fatal(err)
	}
	payload["config"] = map[string]string{"mode": "global"}
	payload["patch"] = map[string]string{"mode": "global"}
	input, _ = json.Marshal(payload)
	run(t, b, "mode", "apply", string(input))
	if s := b.Snapshot(); s.DesiredRunning || s.AppliedRunning || s.Nodes[0].State != "running" {
		t.Fatal("settings shortcut skipped UI node preparation", s)
	}
}

func TestWarmProcessDeathAndStopFence(t *testing.T) {
	for _, interrupted := range []bool{false, true} {
		t.Run(map[bool]string{false: "dead-process", true: "stop-during-warm"}[interrupted], func(t *testing.T) {
			mechanism := newNodeHost()
			b := openNodeHost(t, newStore(t), mechanism)
			node := reservePlan()
			node.Activation = nil
			input := nodeInput(node)
			if interrupted {
				mechanism.blockWake = true
				mechanism.wakeEntered = make(chan struct{})
				if _, err := b.Submit(Request{APIVersion: 1, OperationID: "warm", Method: "warm", Input: Input(input)}); err != nil {
					t.Fatal(err)
				}
				select {
				case <-mechanism.wakeEntered:
				case <-time.After(time.Second):
					t.Fatal("warm did not start external preparation")
				}
				run(t, b, "stop", "stop", "")
				if s := b.Snapshot(); s.DesiredRunning || s.AppliedRunning {
					t.Fatal("late warm enabled runtime", s)
				}
			} else {
				run(t, b, "warm", "warm", input)
				mechanism.mu.Lock()
				delete(mechanism.processes, node.ID)
				mechanism.mu.Unlock()
				run(t, b, "start", "connect", input)
				mechanism.mu.Lock()
				starts := mechanism.starts
				mechanism.mu.Unlock()
				if starts != 2 || b.Snapshot().Observed.State != "running" {
					t.Fatal("dead prepared process was reused", starts)
				}
			}
		})
	}
}

func TestStoppedUICommandsRestoreDeadPreparedNode(t *testing.T) {
	for _, command := range []string{"warm", "selection", "settings"} {
		t.Run(command, func(t *testing.T) {
			h := newHost()
			mechanism := newNodeHost()
			var engine EngineAdapter = selectionHostEngine{hostEngine{h}}
			if command == "settings" {
				engine = liveHostEngine{hostEngine{h}}
			}
			b, err := Open(newStore(t), h, engine, nil, hostPlatform{h}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ManualTicks: true})
			if err != nil {
				t.Fatal(err)
			}
			defer b.Close()
			node := reservePlan()
			node.Activation = nil
			payload := map[string]any{"nodes": []NodePlan{node}, "selected-map": map[string]string{"Pick": "DIRECT"}, "config": map[string]string{"mode": "rule"}, "patch": map[string]string{"mode": "rule"}}
			input, _ := json.Marshal(payload)
			run(t, b, "prepare", "warm", string(input))
			mechanism.mu.Lock()
			delete(mechanism.processes, node.ID)
			mechanism.mu.Unlock()
			method := "warm"
			if command == "selection" {
				method = "apply"
				payload["selected-map"] = map[string]string{"Pick": "REJECT"}
			} else if command == "settings" {
				method = "apply"
				payload["config"] = map[string]string{"mode": "global"}
				payload["patch"] = map[string]string{"mode": "global"}
			}
			input, _ = json.Marshal(payload)
			run(t, b, "refresh-ui", method, string(input))
			mechanism.mu.Lock()
			alive, starts := len(mechanism.processes), mechanism.starts
			mechanism.mu.Unlock()
			if alive != 1 || starts != 2 {
				t.Fatalf("command did not restore dead preparation: processes=%d starts=%d", alive, starts)
			}
			if s := b.Snapshot(); s.DesiredRunning || s.AppliedRunning || s.Observed.State != "stopped" || s.Nodes[0].State != "running" {
				t.Fatal("restoring preparation changed VPN intent or node state", s)
			}
		})
	}
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

// A superseded install of plan B leaves B's node definitions and engine
// configuration behind. Returning to the committed plan A must reinstall A,
// not start B's processes and persist their state under A.
func TestSupersededWarmInstallDoesNotLeaveForeignNodes(t *testing.T) {
	store := newStore(t)
	mechanism := newNodeHost()
	h := newHost()
	b, err := Open(store, h, hostEngine{h}, nil, hostPlatform{h}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ABI: "host", Now: mechanism.now, ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = b.Close() })
	nodeA := reservePlan()
	nodeA.Activation = nil
	nodeB := reservePlan()
	nodeB.Activation = nil
	nodeB.ID = "stormdns-" + strings.Repeat("c", 32)
	nodeB.Name = "StormB"
	nodeB.Port = 36201
	inputA, inputB := nodeInput(nodeA), nodeInput(nodeB)
	run(t, b, "configure", "apply", inputA)
	run(t, b, "ui-warm", "warm", inputA)
	h.mu.Lock()
	h.block, h.entered, h.release = "engine.apply", make(chan struct{}), make(chan struct{})
	h.mu.Unlock()
	if _, err = b.Submit(Request{APIVersion: 1, OperationID: "switch", Method: "apply", Input: Input(inputB)}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("install did not reach the engine")
	}
	if _, err = b.Submit(Request{APIVersion: 1, OperationID: "back", Method: "apply", Input: Input(inputA)}); err != nil {
		t.Fatal(err)
	}
	close(h.release)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if receipt, err := b.Await(ctx, "back"); err != nil || receipt.Status != "succeeded" {
		t.Fatalf("return to committed plan: %+v %v", receipt, err)
	}
	mechanism.mu.Lock()
	_, foreign := mechanism.processes[nodeB.ID]
	_, own := mechanism.processes[nodeA.ID]
	mechanism.mu.Unlock()
	if foreign || !own {
		t.Fatalf("prepared processes do not match plan A: foreign=%v own=%v", foreign, own)
	}
	doc, err := store.Load()
	if err != nil || doc.Applied == nil {
		t.Fatal(err)
	}
	if _, ok := doc.Applied.Nodes[nodeA.ID]; !ok || len(doc.Applied.Nodes) != 1 {
		t.Fatalf("committed node states do not derive from plan A: %+v", doc.Applied.Nodes)
	}
	h.mu.Lock()
	resident := string(h.applied)
	h.mu.Unlock()
	if !strings.Contains(resident, nodeA.ID) || strings.Contains(resident, nodeB.ID) {
		t.Fatalf("engine kept the superseded configuration: %s", resident)
	}
	if s := b.Snapshot(); len(s.Nodes) != 1 || s.Nodes[0].ID != nodeA.ID || s.Nodes[0].State != "running" {
		t.Fatal("node projection does not match plan A", s.Nodes)
	}
}

func TestUIDetachStopsPreparedNodesAndFencesLateWarm(t *testing.T) {
	mechanism := newNodeHost()
	b := openNodeHost(t, newStore(t), mechanism)
	node := reservePlan()
	node.Activation = nil
	input := nodeInput(node)
	processes := func() int {
		mechanism.mu.Lock()
		defer mechanism.mu.Unlock()
		return len(mechanism.processes)
	}
	if err := b.PrepareForUI(); err != nil {
		t.Fatal(err)
	}
	run(t, b, "warm", "warm", input)
	if processes() != 1 {
		t.Fatal("UI preparation did not launch node")
	}
	for range 2 { // idempotent
		if err := b.ReleaseUI(); err != nil {
			t.Fatal(err)
		}
	}
	if s := b.Snapshot(); processes() != 0 || s.DesiredRunning || s.AppliedRunning || s.Nodes[0].State != "stopped" {
		t.Fatal("detach kept latency preparation or changed VPN intent", processes(), s)
	}
	// A warm queued by the detached session prepares the plan without nodes.
	run(t, b, "late-warm", "warm", input)
	if processes() != 0 {
		t.Fatal("late warm recreated UI preparation after detach")
	}
	// Attach/detach facts applied out of arrival order: the older one loses.
	if err := b.SetUISession(false, 2); err != nil {
		t.Fatal(err)
	}
	if err := b.SetUISession(true, 1); err != nil {
		t.Fatal(err)
	}
	run(t, b, "stale-warm", "warm", input)
	if processes() != 0 {
		t.Fatal("stale attach recreated UI preparation")
	}
	// A running VPN keeps its nodes across detach; Stop then releases them.
	if err := b.SetUISession(true, 3); err != nil {
		t.Fatal(err)
	}
	run(t, b, "connect", "connect", input)
	if err := b.SetUISession(false, 4); err != nil {
		t.Fatal(err)
	}
	if processes() != 1 || b.Snapshot().Observed.State != "running" {
		t.Fatal("detach interrupted a running VPN")
	}
	run(t, b, "stop", "stop", "")
	if processes() != 0 {
		t.Fatal("Stop after detach kept UI-only node processes")
	}
}

type parallelNodeHost struct {
	*nodeHost
	entered chan string
	release chan struct{}
}

func (h *parallelNodeHost) Start(ctx context.Context, launch NodeLaunch) error {
	h.entered <- launch.Node.ID
	select {
	case <-h.release:
		return h.nodeHost.Start(ctx, launch)
	case <-ctx.Done():
		return ctx.Err()
	}
}
func TestIndependentNodesStartConcurrently(t *testing.T) {
	mechanism := &parallelNodeHost{nodeHost: newNodeHost(), entered: make(chan string, 4), release: make(chan struct{})}
	engine := newHost()
	b, err := Open(newStore(t), engine, hostEngine{engine}, nil, hostPlatform{engine}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ABI: "host", ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	first := reservePlan()
	first.Activation = nil
	second := first.Clone()
	second.ID = "stormdns-" + strings.Repeat("b", 32)
	second.Port++
	second.Name = "Second"
	_, err = b.Submit(Request{APIVersion: 1, OperationID: "connect", Method: "connect", Input: Input(nodeInput(first, second))})
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		select {
		case <-mechanism.entered:
		case <-time.After(time.Second):
			close(mechanism.release)
			t.Fatal("one node blocked the other's startup")
		}
	}
	close(mechanism.release)
	if _, err = b.Await(context.Background(), "connect"); err != nil {
		t.Fatal(err)
	}
}

func TestManualReserveSelectionDoesNotRequireConnectivity(t *testing.T) {
	mechanism := newNodeHost()
	mechanism.groupHealthy = false
	engine := newHost()
	b, err := Open(newStore(t), engine, selectionHostEngine{hostEngine{engine}}, nil, hostPlatform{engine}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ABI: "host", ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	node := reservePlan()
	node.Name = "Unreachable"
	payload := map[string]any{"nodes": []NodePlan{node}, "selected-map": map[string]string{"Reserve": "DIRECT"}}
	raw, _ := json.Marshal(payload)
	run(t, b, "connect", "connect", string(raw))
	payload["selected-map"] = map[string]string{"Reserve": node.Name}
	raw, _ = json.Marshal(payload)
	run(t, b, "select", "apply", string(raw))
	if s := b.Snapshot(); s.Observed.State != "running" || !s.Nodes[0].Awake {
		t.Fatal("manual unreachable selection failed", s)
	}
}

type readinessNodeHost struct {
	*nodeHost
	listenerChecks int
}

func (h *readinessNodeHost) Listening(ctx context.Context, node NodePlan) (bool, error) {
	h.listenerChecks++
	return h.listenerChecks >= 3, ctx.Err()
}
func (h *readinessNodeHost) TestGroup(ctx context.Context, name string, _ []string) (bool, error) {
	return name == "Storm" && h.listenerChecks >= 3, ctx.Err()
}
func TestAutonomousWakeWaitsForListenerBeforeTestingTheTunnel(t *testing.T) {
	mechanism := &readinessNodeHost{nodeHost: newNodeHost()}
	engine := newHost()
	b, err := Open(newStore(t), engine, hostEngine{engine}, nil, hostPlatform{engine}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ABI: "host", ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	node := reservePlan()
	node.Activation.Wake.Failures = 1
	run(t, b, "connect", "connect", nodeInput(node))
	if err = b.ReconcileNodes(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := b.Snapshot(); !s.Nodes[0].Awake || mechanism.listenerChecks < 3 {
		t.Fatal("wake tested/killed the node before its listener was ready", s)
	}
}

type recoveringNodeHost struct {
	*nodeHost
	attempts int
}

func (h *recoveringNodeHost) Start(ctx context.Context, launch NodeLaunch) error {
	h.attempts++
	if h.attempts < 3 {
		return errors.New("temporary provider failure")
	}
	return h.nodeHost.Start(ctx, launch)
}
func TestOptionalNodeFailureDoesNotRollbackAndRetriesPromptly(t *testing.T) {
	mechanism := &recoveringNodeHost{nodeHost: newNodeHost()}
	engine := newHost()
	b, err := Open(newStore(t), engine, hostEngine{engine}, nil, hostPlatform{engine}, NodeOptions{Adapter: mechanism, Inspection: mechanism, Cache: mechanism, ABI: "host", Now: mechanism.now, ManualTicks: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	node := reservePlan()
	node.Activation = nil
	run(t, b, "connect", "connect", nodeInput(node))
	if s := b.Snapshot(); s.Observed.State != "running" || s.Nodes[0].State != "degraded" {
		t.Fatal("optional node rolled back runtime", s)
	}
	mechanism.advance(5 * time.Second)
	if err = b.ReconcileNodes(context.Background()); err != nil {
		t.Fatal(err)
	}
	if mechanism.attempts != 2 {
		t.Fatal("first retry did not run", mechanism.attempts)
	}
	mechanism.advance(time.Second)
	if err = b.ReconcileNodes(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := b.Snapshot(); mechanism.attempts != 3 || s.Nodes[0].State != "running" {
		t.Fatal("node waited five minutes after a temporary failure", s, mechanism.attempts)
	}
}
