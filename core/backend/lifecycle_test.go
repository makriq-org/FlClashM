package backend

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type leasedPlatform struct {
	hostPlatform
	mu       sync.Mutex
	held     map[string]bool
	acquired chan struct{}
}

func (p *leasedPlatform) BeginOperation(ctx context.Context, id string) error {
	p.mu.Lock()
	p.held[id] = true
	p.mu.Unlock()
	if p.acquired != nil {
		close(p.acquired)
	}
	return ctx.Err()
}
func (p *leasedPlatform) EndOperation(ctx context.Context, id string) error {
	p.mu.Lock()
	delete(p.held, id)
	p.mu.Unlock()
	return ctx.Err()
}
func TestForegroundLeaseCoversPreparationAndCancelledOperation(t *testing.T) {
	h := newHost()
	h.block = "compile"
	h.entered = make(chan struct{})
	h.release = make(chan struct{})
	p := &leasedPlatform{hostPlatform: hostPlatform{h}, held: map[string]bool{}, acquired: make(chan struct{})}
	b, err := Open(newStore(t), h, hostEngine{h}, hostTransports{h}, p)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	_, err = b.Submit(Request{APIVersion: 1, OperationID: "start", Method: "connect", Input: Input(`{"source":"one"}`)})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.entered:
	case <-time.After(time.Second):
		t.Fatal("preparation did not start")
	}
	p.mu.Lock()
	held := p.held["start"]
	p.mu.Unlock()
	if !held {
		t.Fatal("UI could die before host promotion")
	}
	if !b.Cancel("start") {
		t.Fatal("operation not cancellable")
	}
	close(h.release)
	_, _ = b.Await(context.Background(), "start")
	deadline := time.Now().Add(time.Second)
	for {
		p.mu.Lock()
		remaining := len(p.held)
		p.mu.Unlock()
		if remaining == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("cancel leaked foreground resource")
		}
		time.Sleep(time.Millisecond)
	}
	if b.Snapshot().DesiredRunning {
		t.Fatal("cancel retained first-start intent")
	}
}
func TestObservationCannotSupersedeNewUserIntentAndForgetCannotRecoverSecrets(t *testing.T) {
	store := newStore(t)
	h := newHost()
	b := openHost(t, store, h)
	run(t, b, "connect", "connect", `{"credential":"secret"}`)
	observed := b.Snapshot().Generation
	run(t, b, "stop", "stop", "")
	if _, err := b.SubmitAtGeneration(Request{APIVersion: 1, OperationID: "late-os", Method: "recover"}, observed); !errors.Is(err, ErrSuperseded) {
		t.Fatal("stale observation accepted", err)
	}
	run(t, b, "forget", "forget", "")
	document, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if document.Applied != nil || len(document.Desired.Input) > 0 || document.Desired.Running {
		t.Fatal("reset retained recoverable credentials")
	}
	run(t, b, "recover", "recover", "")
	if b.Snapshot().DesiredRunning || b.Snapshot().AppliedGeneration != 0 {
		t.Fatal("reset resurrected old plan")
	}
}

type erasingEngine struct{ hostEngine }

func (e erasingEngine) Forget(ctx context.Context) error {
	e.mu.Lock()
	e.applied = nil
	e.calls = append(e.calls, "engine.forget")
	e.mu.Unlock()
	return ctx.Err()
}
func TestForgetErasesResidentEngineConfiguration(t *testing.T) {
	h := newHost()
	b, err := Open(newStore(t), h, erasingEngine{hostEngine{h}}, hostTransports{h}, hostPlatform{h})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	run(t, b, "start", "connect", `{"secret":"private"}`)
	run(t, b, "erase", "forget", "")
	h.mu.Lock()
	retained := len(h.applied) > 0
	h.mu.Unlock()
	if retained {
		t.Fatal("reset retained resident engine data")
	}
	run(t, b, "fresh", "connect", `{"secret":"new"}`)
	if b.Snapshot().Observed.State != "running" {
		t.Fatal("reset made the engine unusable")
	}
}
