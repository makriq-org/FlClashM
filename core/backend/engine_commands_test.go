package backend

import (
	"context"
	"testing"
)

type commandHostEngine struct{ hostEngine }

func (h commandHostEngine) Command(ctx context.Context, command EngineCommand) error {
	return h.step(ctx, "command."+command.Method)
}

func TestEngineCommandsDoNotPreemptPlansAndAreFencedByStop(t *testing.T) {
	h := newHost()
	store := newStore(t)
	b, err := Open(store, h, commandHostEngine{hostEngine{h}}, hostTransports{h}, hostPlatform{h})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	_, err = b.Submit(Request{APIVersion: 1, OperationID: "connect", Method: "connect", Input: Input(`{"config":"old"}`)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = b.Await(context.Background(), "connect"); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	h.block = "compile"
	h.entered = make(chan struct{})
	h.release = make(chan struct{})
	h.mu.Unlock()
	_, err = b.Submit(Request{APIVersion: 1, OperationID: "switch", Method: "apply", Input: Input(`{"config":"new"}`)})
	if err != nil {
		t.Fatal(err)
	}
	<-h.entered
	_, err = b.SubmitEngineCommand("refresh", EngineCommand{Method: "refresh"})
	if err != nil {
		t.Fatal(err)
	}
	if r, _ := b.Operation("switch"); r.Status != "accepted" {
		t.Fatal("auxiliary command preempted preparation", r)
	}
	_, err = b.Submit(Request{APIVersion: 1, OperationID: "stop", Method: "stop"})
	if err != nil {
		t.Fatal(err)
	}
	close(h.release)
	if _, err = b.Await(context.Background(), "stop"); err != nil {
		t.Fatal(err)
	}
	if r, _ := b.Await(context.Background(), "refresh"); r.Status != "cancelled" {
		t.Fatal(r)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, call := range h.calls {
		if call == "command.refresh" {
			t.Fatal("obsolete effect executed")
		}
	}
}

func TestEngineCommandDurabilityAndIdempotency(t *testing.T) {
	h := newHost()
	store := newStore(t)
	b, err := Open(store, h, commandHostEngine{hostEngine{h}}, hostTransports{h}, hostPlatform{h})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	command := EngineCommand{Method: "connections.close"}
	if _, err = b.SubmitEngineCommand("close", command); err != nil {
		t.Fatal(err)
	}
	if _, err = b.Await(context.Background(), "close"); err != nil {
		t.Fatal(err)
	}
	if r, err := b.SubmitEngineCommand("close", command); err != nil || r.Status != "succeeded" {
		t.Fatal(r, err)
	}
	if _, err = b.SubmitEngineCommand("close", EngineCommand{Method: "different"}); err == nil {
		t.Fatal("operation identity reused")
	}
	if d, err := store.Load(); err != nil || d.Pending != nil || d.Receipts[len(d.Receipts)-1].Status != "succeeded" {
		t.Fatal(d, err)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	count := 0
	for _, call := range h.calls {
		if call == "command.connections.close" {
			count++
		}
	}
	if count != 1 {
		t.Fatal(count)
	}
}
