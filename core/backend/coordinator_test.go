package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// This host deliberately has no Android or mihomo dependency. Failure injection
// exercises the application protocol, not source text or adapter call signatures.
type host struct {
	mu       sync.Mutex
	calls    []string
	states   map[string]bool
	fail     string
	block    string
	entered  chan struct{}
	release  chan struct{}
	applied  json.RawMessage
	compiles int
}

func newHost() *host { return &host{states: make(map[string]bool)} }
func (h *host) step(ctx context.Context, name string) error {
	h.mu.Lock()
	h.calls = append(h.calls, name)
	fail := h.fail == name
	if fail {
		h.fail = ""
	}
	block := h.block == name
	if block {
		h.block = ""
		close(h.entered)
	}
	h.mu.Unlock()
	if block {
		<-h.release
		return nil
	} // Intentionally ignores cancellation: test stale success.
	if fail {
		return errors.New("injected " + name)
	}
	return ctx.Err()
}
func (h *host) Compile(ctx context.Context, input Input, generation uint64) (*RuntimePlan, error) {
	h.mu.Lock()
	h.compiles++
	h.mu.Unlock()
	if err := h.step(ctx, "compile"); err != nil {
		return nil, err
	}
	return NewRuntimePlan(generation, json.RawMessage(input))
}

type hostEngine struct{ *host }

func (h hostEngine) Apply(ctx context.Context, p *RuntimePlan) error {
	if err := h.step(ctx, "engine.apply"); err != nil {
		return err
	}
	h.mu.Lock()
	h.applied = p.Payload()
	h.mu.Unlock()
	return nil
}
func (h hostEngine) Start(ctx context.Context) error                  { return h.set(ctx, "engine", true) }
func (h hostEngine) Stop(ctx context.Context) error                   { return h.set(ctx, "engine", false) }
func (h hostEngine) Observe(ctx context.Context) (Observation, error) { return h.read(ctx, "engine") }

type hostTransports struct{ *host }

func (h hostTransports) Prepare(ctx context.Context, p *RuntimePlan) error {
	return h.step(ctx, "transports.prepare")
}
func (h hostTransports) Start(ctx context.Context, p *RuntimePlan) error {
	return h.set(ctx, "transports", true)
}
func (h hostTransports) Stop(ctx context.Context) error { return h.set(ctx, "transports", false) }
func (h hostTransports) Observe(ctx context.Context) (Observation, error) {
	return h.read(ctx, "transports")
}

type hostPlatform struct{ *host }

func (h hostPlatform) Start(ctx context.Context, p *RuntimePlan) error {
	return h.set(ctx, "platform", true)
}
func (h hostPlatform) Stop(ctx context.Context) error { return h.set(ctx, "platform", false) }
func (h hostPlatform) Observe(ctx context.Context) (Observation, error) {
	return h.read(ctx, "platform")
}
func (h *host) set(ctx context.Context, name string, value bool) error {
	suffix := ".stop"
	if value {
		suffix = ".start"
	}
	if err := h.step(ctx, name+suffix); err != nil {
		return err
	}
	h.mu.Lock()
	h.states[name] = value
	h.mu.Unlock()
	return nil
}
func (h *host) read(ctx context.Context, name string) (Observation, error) {
	if err := h.step(ctx, name+".observe"); err != nil {
		return Observation{State: "unknown"}, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	state := "stopped"
	if h.states[name] {
		state = "running"
	}
	return Observation{State: state}, nil
}
func openHost(t *testing.T, store Store, h *host) *Backend {
	t.Helper()
	b, err := Open(store, h, hostEngine{h}, hostTransports{h}, hostPlatform{h})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = b.Close() })
	return b
}
func newStore(t *testing.T) *FileStore {
	t.Helper()
	s, err := NewFileStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return s
}
func run(t *testing.T, b *Backend, id, method string, input string) Receipt {
	t.Helper()
	r, err := b.Submit(Request{APIVersion: APIVersion, OperationID: id, Method: method, Input: Input(input)})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r, err = b.Await(ctx, r.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != "succeeded" {
		t.Fatalf("operation failed: %+v", r)
	}
	return r
}
func expectFailure(t *testing.T, b *Backend, id, method, input string) {
	t.Helper()
	_, err := b.Submit(Request{APIVersion: APIVersion, OperationID: id, Method: method, Input: Input(input)})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r, err := b.Await(ctx, id)
	if err == nil || r.Status == "succeeded" {
		t.Fatalf("expected failed operation: %+v, %v", r, err)
	}
}
func TestLifecycleAndReopen(t *testing.T) {
	store := newStore(t)
	h := newHost()
	b := openHost(t, store, h)
	applied := run(t, b, "configure", "apply", `{"profile":"one"}`)
	if b.Snapshot().AppliedGeneration != applied.Generation || b.Snapshot().Observed.State != "stopped" {
		t.Fatal(b.Snapshot())
	}
	run(t, b, "start", "start", "")
	s := b.Snapshot()
	if !s.DesiredRunning || !s.AppliedRunning || s.Observed.State != "running" || s.StartedAt == 0 {
		t.Fatal(s)
	}
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := openHost(t, store, newHost())
	if recovered.Snapshot().InstanceID == s.InstanceID {
		t.Fatal("reopened backend reused instance identity")
	}
	if recovered.Snapshot().Observed.State != "unknown" {
		t.Fatal("reopen must not claim an unobserved tunnel")
	}
	run(t, recovered, "recover", "recover", "")
	if recovered.Snapshot().Observed.State != "running" || recovered.Snapshot().Sequence <= s.Sequence {
		t.Fatal(recovered.Snapshot())
	}
	run(t, recovered, "stop", "stop", "")
	if recovered.Snapshot().DesiredRunning || recovered.Snapshot().AppliedRunning {
		t.Fatal(recovered.Snapshot())
	}
	run(t, recovered, "recover-stopped", "recover", "")
	if recovered.Snapshot().Observed.State != "stopped" {
		t.Fatal("explicit stop resurrected")
	}
}
func TestRollbackEveryExecutionBoundary(t *testing.T) {
	for _, step := range []string{"compile", "transports.prepare", "transports.start", "engine.apply", "engine.start", "platform.start", "engine.observe", "transports.observe", "platform.observe"} {
		t.Run(step, func(t *testing.T) {
			store := newStore(t)
			h := newHost()
			b := openHost(t, store, h)
			run(t, b, "configure", "apply", `{"profile":"old"}`)
			run(t, b, "start", "start", "")
			old := b.Snapshot().AppliedGeneration
			h.mu.Lock()
			h.fail = step
			h.mu.Unlock()
			expectFailure(t, b, "switch", "apply", `{"profile":"new"}`)
			s := b.Snapshot()
			if s.AppliedGeneration != old || s.Observed.State != "running" {
				t.Fatal(s)
			}
			h.mu.Lock()
			payload := string(h.applied)
			h.mu.Unlock()
			if payload != `{"profile":"old"}` {
				t.Fatal(payload)
			}
			doc, err := store.Load()
			if err != nil || doc.Pending == nil || doc.Applied.Plan.Generation != old {
				t.Fatalf("lost journal: %+v %v", doc, err)
			}
			_ = b.Close()
			reopened := openHost(t, store, newHost())
			run(t, reopened, "recovery", "recover", "")
			doc, err = store.Load()
			if err != nil || string(doc.Applied.Input) != `{"profile":"old"}` || doc.Pending != nil {
				t.Fatalf("bad recovery: %+v %v", doc, err)
			}
		})
	}
}
func TestStopPreemptsLateSuccessAndNeverCompiles(t *testing.T) {
	h := newHost()
	b := openHost(t, newStore(t), h)
	run(t, b, "configure", "apply", `{"profile":"old"}`)
	run(t, b, "start", "start", "")
	h.mu.Lock()
	h.block = "engine.apply"
	h.entered = make(chan struct{})
	h.release = make(chan struct{})
	h.mu.Unlock()
	_, err := b.Submit(Request{APIVersion: 1, OperationID: "slow", Method: "apply", Input: Input(`{"profile":"late"}`)})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("not entered")
	}
	_, err = b.Submit(Request{APIVersion: 1, OperationID: "stop", Method: "stop"})
	if err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	compiled := h.compiles
	h.mu.Unlock()
	close(h.release)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err = b.Await(ctx, "slow"); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err = b.Await(ctx, "stop"); err != nil {
		t.Fatal(err)
	}
	s := b.Snapshot()
	if s.DesiredRunning || s.AppliedRunning || s.Observed.State != "stopped" {
		t.Fatal(s)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.compiles != compiled {
		t.Fatal("Stop compiled a profile")
	}
	for _, running := range h.states {
		if running {
			t.Fatal("resource survived stop")
		}
	}
}
func TestSubmitOwnsInputAndWaitCancellationDoesNotCancelRuntime(t *testing.T) {
	h := newHost()
	b := openHost(t, newStore(t), h)
	h.block = "compile"
	h.entered = make(chan struct{})
	h.release = make(chan struct{})
	input := Input(`{"profile":"old"}`)
	_, err := b.Submit(Request{APIVersion: 1, OperationID: "submit", Method: "apply", Input: input})
	if err != nil {
		t.Fatal(err)
	}
	input[12] = 'X'
	<-h.entered
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = b.Await(ctx, "submit"); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	close(h.release)
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	if _, err = b.Await(ctx, "submit"); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if string(h.applied) != `{"profile":"old"}` {
		t.Fatal(string(h.applied))
	}
}
func TestIdempotencyVersionAndOperationConflict(t *testing.T) {
	store := newStore(t)
	h := newHost()
	b := openHost(t, store, h)
	request := Request{APIVersion: 1, OperationID: "same", Method: "apply", Input: Input(`{"a":1,"b":2}`)}
	run(t, b, request.OperationID, request.Method, string(request.Input))
	h.mu.Lock()
	calls := len(h.calls)
	h.mu.Unlock()
	request.Input = Input(`{ "b":2, "a":1 }`)
	receipt, err := b.Submit(request)
	if err != nil || receipt.Status != "succeeded" {
		t.Fatalf("duplicate: %+v %v", receipt, err)
	}
	request.Input = Input(`{"a":2}`)
	if _, err = b.Submit(request); err == nil {
		t.Fatal("accepted conflicting ID")
	}
	request.APIVersion = 2
	if _, err = b.Submit(request); err == nil {
		t.Fatal("accepted unknown API")
	}
	h.mu.Lock()
	if len(h.calls) != calls {
		t.Fatal("duplicate/version check had side effects")
	}
	h.mu.Unlock()
	_ = b.Close()
	reopened := openHost(t, store, newHost())
	request.APIVersion = 1
	request.Input = Input(`{"b":2,"a":1}`)
	if r, err := reopened.Submit(request); err != nil || r.Status != "succeeded" {
		t.Fatalf("receipt lost on reopen: %+v %v", r, err)
	}
}
func TestSnapshotSubscribeOverflowAndDetach(t *testing.T) {
	b := openHost(t, newStore(t), newHost())
	events, detach := b.Subscribe(1)
	initial := <-events
	run(t, b, "configure", "apply", `{"profile":"one"}`)
	latest := <-events
	if !latest.ResyncRequired || latest.Snapshot.Sequence <= initial.Snapshot.Sequence {
		t.Fatal(latest)
	}
	detach()
	detach()
	run(t, b, "start", "start", "")
	if b.Snapshot().Observed.State != "running" {
		t.Fatal("UI detach stopped runtime")
	}
	if _, ok := <-events; ok {
		t.Fatal("subscription not closed")
	}
}
func TestFileStoreVersionsCorruptionAndPlanImmutability(t *testing.T) {
	t.Run("plan", func(t *testing.T) {
		nested := map[string]any{"child": map[string]any{"secret": "old"}}
		p, err := NewRuntimePlan(1, nested)
		if err != nil {
			t.Fatal(err)
		}
		nested["child"].(map[string]any)["secret"] = "changed"
		raw := p.Payload()
		raw[0] = '['
		data := p.Data()
		data.Payload[0] = '['
		if string(p.Payload()) != `{"child":{"secret":"old"}}` {
			t.Fatal(string(p.Payload()))
		}
		data = p.Data()
		data.Digest = "broken"
		if _, err = RestorePlan(data); err == nil {
			t.Fatal("accepted tampered plan")
		}
	})
	for _, raw := range []string{`{"version":99}`, `{"version":1,`, strings.Repeat("x", maxStateBytes+1)} {
		t.Run(fmt.Sprint(len(raw)), func(t *testing.T) {
			s := newStore(t)
			if err := os.WriteFile(s.path, []byte(raw), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := s.Load(); err == nil {
				t.Fatal("accepted invalid store")
			}
			if err := s.Save(newDocument()); err == nil {
				t.Fatal("overwrote invalid/newer store")
			}
			unchanged, _ := os.ReadFile(s.path)
			if string(unchanged) != raw {
				t.Fatal("store changed")
			}
		})
	}
	t.Run("atomic", func(t *testing.T) {
		s := newStore(t)
		doc := newDocument()
		if err := s.Save(doc); err != nil {
			t.Fatal(err)
		}
		doc.Generation = 3
		if err := s.Save(doc); err != nil {
			t.Fatal(err)
		}
		got, err := s.Load()
		if err != nil || !reflect.DeepEqual(got, doc) {
			t.Fatalf("%+v %v", got, err)
		}
		info, err := os.Stat(s.path)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("private state permissions: %v %v", info, err)
		}
		files, _ := filepath.Glob(filepath.Join(filepath.Dir(s.path), ".backend-*"))
		if len(files) != 0 {
			t.Fatal(files)
		}
	})
}

type failingStore struct {
	Store
	failNextCommit bool
	onFailure      func()
}

func (s *failingStore) Save(d Document) error {
	if s.failNextCommit && d.Pending == nil && d.Applied != nil {
		s.failNextCommit = false
		if s.onFailure != nil {
			s.onFailure()
		}
		return errors.New("injected commit failure")
	}
	return s.Store.Save(d)
}
func TestCommitFailureAndRollbackFailureRemainRecoverable(t *testing.T) {
	for _, failRollback := range []bool{false, true} {
		t.Run(fmt.Sprint(failRollback), func(t *testing.T) {
			h := newHost()
			store := &failingStore{Store: newStore(t)}
			b := openHost(t, store, h)
			run(t, b, "configure", "apply", `{"profile":"old"}`)
			run(t, b, "start", "start", "")
			generation := b.Snapshot().AppliedGeneration
			store.failNextCommit = true
			if failRollback {
				store.onFailure = func() { h.mu.Lock(); h.fail = "platform.start"; h.mu.Unlock() }
			}
			expectFailure(t, b, "new", "apply", `{"profile":"uncommitted"}`)
			s := b.Snapshot()
			if s.AppliedGeneration != generation {
				t.Fatal("advanced an uncommitted generation")
			}
			expected := "running"
			if failRollback {
				expected = "degraded"
			}
			if s.Observed.State != expected {
				t.Fatal(s)
			}
			doc, err := store.Load()
			if err != nil || doc.Pending == nil {
				t.Fatalf("missing pending journal: %+v %v", doc, err)
			}
			_ = b.Close()
			reopened := openHost(t, store, newHost())
			run(t, reopened, "recover", "recover", "")
			doc, _ = store.Load()
			if string(doc.Applied.Input) != `{"profile":"old"}` {
				t.Fatal(string(doc.Applied.Input))
			}
		})
	}
}
func TestExplicitCancelRestoresOldIntent(t *testing.T) {
	h := newHost()
	store := newStore(t)
	b := openHost(t, store, h)
	run(t, b, "configure", "apply", `{"profile":"old"}`)
	run(t, b, "start", "start", "")
	h.mu.Lock()
	h.block = "engine.apply"
	h.entered = make(chan struct{})
	h.release = make(chan struct{})
	h.mu.Unlock()
	_, err := b.Submit(Request{APIVersion: 1, OperationID: "cancel-me", Method: "apply", Input: Input(`{"profile":"cancelled"}`)})
	if err != nil {
		t.Fatal(err)
	}
	<-h.entered
	if !b.Cancel("cancel-me") {
		t.Fatal("cancel rejected")
	}
	close(h.release)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err = b.Await(ctx, "cancel-me"); err == nil {
		t.Fatal("cancellation succeeded")
	}
	doc, err := store.Load()
	if err != nil || string(doc.Desired.Input) != `{"profile":"old"}` {
		t.Fatalf("cancelled intent survived: %+v %v", doc, err)
	}
	if b.Snapshot().Observed.State != "running" {
		t.Fatal(b.Snapshot())
	}
}
func TestJSONAPIRejectsMalformedRequestsWithoutSideEffects(t *testing.T) {
	h := newHost()
	b := openHost(t, newStore(t), h)
	for _, raw := range []string{`null`, `[]`, `{}`, `{"apiVersion":2,"operationId":"x","method":"stop"}`, `{"apiVersion":1,"operationId":"x","method":"stop","unknown":1}`, `{"apiVersion":1,"operationId":"x","method":"apply","params":null}`} {
		var response Response
		if err := json.Unmarshal(b.Handle([]byte(raw)), &response); err != nil {
			t.Fatal(err)
		}
		if response.Error == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.calls) != 0 {
		t.Fatal(h.calls)
	}
}

func TestInterruptedIntentRecoversOnlyCommittedPlan(t *testing.T) {
	for _, running := range []bool{false, true} {
		t.Run(fmt.Sprint(running), func(t *testing.T) {
			store := newStore(t)
			b := openHost(t, store, newHost())
			run(t, b, "configure", "apply", `{"profile":"committed"}`)
			run(t, b, "start", "start", "")
			_ = b.Close()
			doc, err := store.Load()
			if err != nil {
				t.Fatal(err)
			}
			interrupted := Request{APIVersion: 1, OperationID: "interrupted", Method: "apply", Input: Input(`{"profile":"uncommitted"}`)}
			fp, _ := fingerprint(interrupted)
			doc.Generation++
			doc.Desired = Desired{Running: running, Input: interrupted.Input}
			doc.Pending = &Pending{OperationID: "interrupted", Fingerprint: fp, Method: "apply", Generation: doc.Generation}
			if err = store.Save(doc); err != nil {
				t.Fatal(err)
			}
			recovered := openHost(t, store, newHost())
			run(t, recovered, "recover", "recover", "")
			doc, _ = store.Load()
			if string(doc.Applied.Input) != `{"profile":"committed"}` || doc.Applied.Running != running {
				t.Fatalf("replayed uncommitted switch: %+v", doc.Applied)
			}
			receipt, err := recovered.Operation("interrupted")
			if err != nil || receipt.Status != "interrupted" {
				t.Fatalf("lost interrupted outcome: %+v %v", receipt, err)
			}
			duplicate, err := recovered.Submit(interrupted)
			if err != nil || duplicate.Status != "interrupted" {
				t.Fatalf("replayed interrupted ID: %+v %v", duplicate, err)
			}
		})
	}
}
func TestCleanupFailureNeverClaimsStopped(t *testing.T) {
	h := newHost()
	b := openHost(t, newStore(t), h)
	run(t, b, "configure", "apply", `{"profile":"one"}`)
	run(t, b, "start", "start", "")
	h.mu.Lock()
	h.fail = "platform.stop"
	h.mu.Unlock()
	expectFailure(t, b, "stop", "stop", "")
	s := b.Snapshot()
	if s.Observed.State == "stopped" || s.DesiredRunning {
		t.Fatal(s)
	}
	run(t, b, "retry", "stop", "")
	if b.Snapshot().Observed.State != "stopped" {
		t.Fatal(b.Snapshot())
	}
}

func TestRecoveryDoesNotReplayFirstUncommittedProfile(t *testing.T) {
	store := newStore(t)
	doc := newDocument()
	doc.Generation = 7
	doc.Desired = Desired{Running: true, Input: Input(`{"profile":"never-committed"}`)}
	doc.Pending = &Pending{OperationID: "lost", Fingerprint: "lost-fingerprint", Method: "apply", Generation: 7}
	if err := store.Save(doc); err != nil {
		t.Fatal(err)
	}
	h := newHost()
	b := openHost(t, store, h)
	run(t, b, "recover", "recover", "")
	s := b.Snapshot()
	if s.AppliedGeneration != 0 || s.DesiredRunning || s.Observed.State != "stopped" {
		t.Fatal(s)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.compiles != 0 {
		t.Fatal("compiled an uncommitted first profile")
	}
}
