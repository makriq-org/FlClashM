package service

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"core/backend"
	"core/backend/compile"
)

type testEngine struct {
	mu      sync.Mutex
	running bool
	payload json.RawMessage
	starts  int
	fail    bool
}

func (e *testEngine) Apply(ctx context.Context, plan *backend.RuntimePlan) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.fail {
		e.fail = false
		return errors.New("injected engine failure")
	}
	e.payload = plan.Payload()
	return nil
}
func (e *testEngine) Start(ctx context.Context) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.running = true
	e.starts++
	return ctx.Err()
}
func (e *testEngine) Stop(ctx context.Context) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.running = false
	return ctx.Err()
}
func (e *testEngine) Observe(ctx context.Context) (backend.Observation, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	state := "stopped"
	if e.running {
		state = "running"
	}
	return backend.Observation{State: state}, ctx.Err()
}

type testPlatform struct {
	mu      sync.Mutex
	running bool
}

func (p *testPlatform) Start(ctx context.Context, _ *backend.RuntimePlan) error {
	p.mu.Lock()
	p.running = true
	p.mu.Unlock()
	return ctx.Err()
}
func (p *testPlatform) Stop(ctx context.Context) error {
	p.mu.Lock()
	p.running = false
	p.mu.Unlock()
	return ctx.Err()
}
func (p *testPlatform) Observe(ctx context.Context) (backend.Observation, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	state := "stopped"
	if p.running {
		state = "running"
	}
	return backend.Observation{State: state}, ctx.Err()
}

type testNodeMechanism struct{}

func (testNodeMechanism) Prepare(context.Context, backend.NodePlan) error { return nil }
func (testNodeMechanism) Start(context.Context, backend.NodeLaunch) error {
	return errors.New("unexpected external process")
}
func (testNodeMechanism) Stop(context.Context, string) error { return nil }
func (testNodeMechanism) StopAll(context.Context) error      { return nil }
func (testNodeMechanism) Observe(context.Context, string) (backend.Observation, error) {
	return backend.Observation{State: "stopped"}, nil
}
func (testNodeMechanism) Listening(context.Context, backend.NodePlan) (bool, error) {
	return false, nil
}
func (testNodeMechanism) AllocatePort(context.Context) (int, error) {
	return 0, errors.New("unexpected external process")
}
func (testNodeMechanism) Probe(context.Context, backend.NodeProbe) (bool, error)    { return false, nil }
func (testNodeMechanism) HasNetwork(context.Context) (bool, error)                  { return true, nil }
func (testNodeMechanism) TestGroup(context.Context, string, []string) (bool, error) { return true, nil }
func (testNodeMechanism) Selected(context.Context, []string) (map[string]string, error) {
	return map[string]string{}, nil
}
func (testNodeMechanism) Connections(context.Context) ([][]string, error) { return nil, nil }
func (testNodeMechanism) NetworkScope(context.Context) (string, error)    { return "host", nil }
func (testNodeMechanism) Read(context.Context, string, string) (backend.StrategyCache, error) {
	return backend.StrategyCache{}, nil
}
func (testNodeMechanism) Write(context.Context, string, string, backend.StrategyCache) error {
	return nil
}
func options(t *testing.T, directory string, engine *testEngine, ticks <-chan time.Time) Options {
	t.Helper()
	host := testNodeMechanism{}
	compiler := &compile.Compiler{Capabilities: compile.Capabilities{Platform: "android", HomeDir: directory, ProfilesDir: directory + "/profiles"}, Validate: func(ctx context.Context, config compile.Object) error { return ctx.Err() }}
	return Options{Directory: directory + "/backend", Compiler: compiler, ValidateSource: func(ctx context.Context, source string) error { _, err := compile.ParseProfile(source); return err }, Engine: engine, Platform: &testPlatform{}, Nodes: backend.NodeOptions{Adapter: host, Inspection: host, Cache: host, ABI: "host", ManualTicks: true}, Ticks: ticks, UserAgent: "Fixture/1"}
}
func openTestApp(t *testing.T, options Options) *App {
	t.Helper()
	app, err := Open(options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = app.Close() })
	return app
}
func request(t *testing.T, app *App, id, method string, params any) json.RawMessage {
	t.Helper()
	raw, _ := json.Marshal(params)
	if params == nil {
		raw = nil
	}
	// Match Kotlin/Flutter's literal wire request, independently of Go DTO encoding.
	wire := map[string]any{"apiVersion": 1, "operationId": id, "method": method}
	if params != nil {
		wire["params"] = json.RawMessage(raw)
	}
	encoded, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		Result json.RawMessage   `json:"result"`
		Error  *backend.APIError `json:"error"`
	}
	if err := json.Unmarshal(app.Handle(encoded), &response); err != nil {
		t.Fatal(err)
	}
	if response.Error != nil {
		t.Fatalf("%s: %s", method, response.Error.Message)
	}
	return response.Result
}
func waitDomain(t *testing.T, app *App, id string) Receipt {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	receipt, err := app.Await(ctx, id)
	if err != nil || receipt.Status != "succeeded" {
		t.Fatalf("application operation: %#v %v", receipt, err)
	}
	if receipt.RuntimeOperationID != "" {
		if _, err = app.runtime.Await(ctx, receipt.RuntimeOperationID); err != nil {
			t.Fatal(err)
		}
	}
	return receipt
}
func waitRuntime(t *testing.T, app *App, id string) backend.Receipt {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	receipt, err := app.runtime.Await(ctx, id)
	if err != nil || receipt.Status != "succeeded" {
		t.Fatalf("runtime operation: %#v %v", receipt, err)
	}
	return receipt
}
func waitCondition(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition did not become true")
}

func TestDeletingActiveProfileSelectsFirstAndLastDeletionStopsVPN(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	for _, id := range []string{"one", "two"} {
		request(t, app, "add-"+id, "profile.put", map[string]any{"metadata": map[string]any{"id": id}, "source": "rules: ['MATCH,DIRECT']\n", "select": id == "two"})
		waitDomain(t, app, "add-"+id)
	}
	request(t, app, "connect-deletion", "runtime.start", nil)
	waitRuntime(t, app, "connect-deletion")
	two, _ := app.profiles.Get("two")
	request(t, app, "delete-two", "profile.delete", map[string]any{"profileId": "two", "expectedRevision": two.Revision})
	waitDomain(t, app, "delete-two")
	if !app.isCurrent("one") || !app.Snapshot().Runtime.AppliedRunning {
		t.Fatal("remaining profile was not selected while preserving VPN")
	}
	one, _ := app.profiles.Get("one")
	request(t, app, "delete-last", "profile.delete", map[string]any{"profileId": "one", "expectedRevision": one.Revision})
	waitDomain(t, app, "delete-last")
	if app.Snapshot().Runtime.DesiredRunning || app.Snapshot().Runtime.Observed.State != "stopped" {
		t.Fatal("deleting the last profile left VPN running")
	}
}

func TestResolvedProviderSettingsRemainFallbackWithoutFlutter(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	request(t, app, "hinted", "profile.put", map[string]any{"metadata": map[string]any{"id": "hinted", "providerHeaders": map[string]string{"flclashm-globalmode": "false"}}, "source": "mixed-port: 9091\nrules: ['MATCH,DIRECT']\n", "select": true})
	waitDomain(t, app, "hinted")
	waitCondition(t, func() bool {
		var patch map[string]any
		_ = json.Unmarshal(app.Snapshot().Catalog.Settings["patchClashConfig"], &patch)
		return patch["mixed-port"] == float64(9091)
	})
	request(t, app, "global-disabled", "settings.patch", map[string]any{"patch": map[string]any{"patchClashConfig": map[string]any{"mode": "global"}}})
	waitDomain(t, app, "global-disabled")
	waitCondition(t, func() bool {
		var patch map[string]any
		_ = json.Unmarshal(app.Snapshot().Catalog.Settings["patchClashConfig"], &patch)
		return patch["mode"] == "rule"
	})
	request(t, app, "plain", "profile.put", map[string]any{"metadata": map[string]any{"id": "plain"}, "source": "rules: ['MATCH,DIRECT']\n", "select": true})
	waitDomain(t, app, "plain")
	view, err := app.RuntimeView()
	if err != nil {
		t.Fatal(err)
	}
	var payload struct {
		Config map[string]any `json:"config"`
	}
	_ = json.Unmarshal(view, &payload)
	if payload.Config["mixed-port"] != float64(9091) {
		t.Fatal("switching to an unhinted profile lost the retained fallback", payload.Config)
	}
}
func TestApplicationProfilesRuntimeAndDetachedUI(t *testing.T) {
	directory := t.TempDir()
	opts := options(t, directory, &testEngine{}, make(chan time.Time))
	app := openTestApp(t, opts)
	request(t, app, "import", "profile.put", map[string]any{"metadata": map[string]any{"id": "one", "label": "First"}, "source": "proxies: []\nrules: ['MATCH,DIRECT']\n", "select": true})
	receipt := waitDomain(t, app, "import")
	if receipt.ProfileID != "one" {
		t.Fatal(receipt)
	}
	request(t, app, "start", "runtime.start", nil)
	waitRuntime(t, app, "start")
	snapshot, events, detach := app.Subscribe(1)
	if !snapshot.Runtime.AppliedRunning {
		t.Fatal(snapshot)
	}
	detach()
	if _, ok := <-events; ok {
		t.Fatal("UI event subscription not detached")
	}
	request(t, app, "rename", "profile.put", map[string]any{"metadata": map[string]any{"id": "one", "label": "Renamed"}, "expectedRevision": receipt.Revision})
	waitDomain(t, app, "rename")
	if app.Snapshot().Runtime.Observed.State != "running" {
		t.Fatal("UI detachment interrupted VPN")
	}
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	// Supplying different legacy data cannot overwrite a completed migration.
	opts = options(t, directory, &testEngine{}, make(chan time.Time))
	opts.LegacySettings = []byte(`{"profiles":[],"currentProfileId":null}`)
	reopened := openTestApp(t, opts)
	waitCondition(t, func() bool { return reopened.Snapshot().Runtime.Observed.State == "running" })
	record, err := reopened.ProfileSource("one")
	if err != nil || string(record.Metadata["label"]) != `"Renamed"` || !strings.Contains(record.Source, "MATCH,DIRECT") {
		t.Fatal("profile migration/reopen", record, err)
	}
	if result := request(t, reopened, "retry-import", "operation.get", map[string]any{"operationId": "import"}); !strings.Contains(string(result), `"status":"succeeded"`) {
		t.Fatal(string(result))
	}
	request(t, reopened, "stop", "runtime.stop", nil)
	waitRuntime(t, reopened, "stop")
}
func TestHeadlessSubscriptionAndStopDuringResponse(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var requestMu sync.Mutex
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestMu.Lock()
		requests++
		number := requests
		requestMu.Unlock()
		if number == 2 {
			close(entered)
			<-release
		}
		_, _ = w.Write([]byte("proxies: []\nrules: ['MATCH,DIRECT']\n# response"))
	}))
	defer server.Close()
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	ticks := make(chan time.Time, 1)
	opts := options(t, t.TempDir(), &testEngine{}, ticks)
	opts.HTTPClient = server.Client()
	opts.Now = func() time.Time { return now }
	app := openTestApp(t, opts)
	request(t, app, "download", "profile.import.url", map[string]any{"metadata": map[string]any{"id": "one", "url": server.URL, "autoUpdateDuration": int64(time.Second / time.Microsecond)}, "select": true})
	waitDomain(t, app, "download")
	request(t, app, "start", "runtime.start", nil)
	waitRuntime(t, app, "start")
	_, _, detach := app.Subscribe(1)
	detach()
	priorRevision := app.Snapshot().Catalog.Revision
	ticks <- now.Add(2 * time.Second)
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("headless refresh did not run")
	}
	request(t, app, "stop", "runtime.stop", nil)
	waitRuntime(t, app, "stop")
	close(release)
	waitCondition(t, func() bool {
		requestMu.Lock()
		count := requests
		requestMu.Unlock()
		return count == 2 && app.Snapshot().Catalog.Revision > priorRevision && app.Snapshot().Runtime.OperationID == ""
	})
	if snapshot := app.Snapshot(); snapshot.Runtime.DesiredRunning || snapshot.Runtime.AppliedRunning {
		t.Fatal("late subscription response restarted VPN", snapshot.Runtime)
	}
	record, err := app.ProfileSource("one")
	if err != nil || string(record.Metadata["url"]) != `"`+server.URL+`"` {
		t.Fatal("metadata update lost URL", record, err)
	}
}

func TestIdenticalRuntimePlanKeepsStartTimeAndService(t *testing.T) {
	engine := &testEngine{}
	app := openTestApp(t, options(t, t.TempDir(), engine, make(chan time.Time)))
	request(t, app, "fixture", "profile.put", map[string]any{"metadata": map[string]any{"id": "one"}, "source": "rules: ['MATCH,DIRECT']", "select": true})
	waitDomain(t, app, "fixture")
	request(t, app, "start-1", "runtime.start", nil)
	waitRuntime(t, app, "start-1")
	first := app.Snapshot().Runtime
	engine.mu.Lock()
	starts := engine.starts
	engine.mu.Unlock()
	request(t, app, "start-2", "runtime.start", nil)
	waitRuntime(t, app, "start-2")
	second := app.Snapshot().Runtime
	engine.mu.Lock()
	after := engine.starts
	engine.mu.Unlock()
	if starts != after || first.StartedAt != second.StartedAt || second.AppliedGeneration <= first.AppliedGeneration {
		t.Fatal("identical plan restarted service", first, second, starts, after)
	}
	encoded, _ := json.Marshal(backend.Request{APIVersion: 1, OperationID: "start-1", Method: "runtime.stop"})
	var response backend.Response
	_ = json.Unmarshal(app.Handle(encoded), &response)
	if response.Error == nil || !app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("operationId reused for a different command", response)
	}
	request(t, app, "restart", "runtime.restart", nil)
	waitRuntime(t, app, "restart")
	engine.mu.Lock()
	after = engine.starts
	engine.mu.Unlock()
	if after != starts+1 {
		t.Fatal("explicit restart optimized away")
	}
}

func TestLegacyActiveMigrationAndExplicitStopUseOneExecutor(t *testing.T) {
	directory := t.TempDir()
	opts := options(t, directory, &testEngine{}, make(chan time.Time))
	opts.LegacyRunning = true
	opts.LegacySettings = []byte(`{"profiles":[{"id":"legacy","url":"","autoUpdateDuration":86400000000}],"currentProfileId":"legacy"}`)
	opts.ReadLegacySource = func(id string) (string, error) { return "proxies: []\nrules: ['MATCH,DIRECT']\n", nil }
	app := openTestApp(t, opts)
	waitCondition(t, func() bool { return app.Snapshot().Runtime.Observed.State == "running" })
	_, input, err := app.runtime.Applied()
	if err != nil || !strings.Contains(string(input), "legacy") {
		t.Fatal("legacy source not compiled", err)
	}
	request(t, app, "user-stop", "runtime.stop", nil)
	waitRuntime(t, app, "user-stop")
	if err = app.Close(); err != nil {
		t.Fatal(err)
	}
	opts.Engine = &testEngine{}
	opts.Platform = &testPlatform{}
	restored := openTestApp(t, opts)
	waitCondition(t, func() bool { return restored.Snapshot().Runtime.Observed.State == "stopped" })
	if restored.Snapshot().Runtime.DesiredRunning {
		t.Fatal("old Kotlin active marker overrode an explicit Go Stop")
	}
}
