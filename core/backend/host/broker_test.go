package host

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestCancelledRequestRejectsLateResult(t *testing.T) {
	requests := make(chan Request, 4)
	b := &Broker{Send: func(r Request) { requests <- r }}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- b.Call(ctx, "vpn.start", nil, nil) }()
	r := <-requests
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if c := <-requests; c.ID != r.ID || c.Method != "request.cancel" {
		t.Fatal(c)
	}
	if b.Complete(Result{ID: r.ID, Value: json.RawMessage(`true`)}) {
		t.Fatal("late result accepted")
	}
	go func() { done <- b.Call(context.Background(), "vpn.stop", nil, nil) }()
	next := <-requests
	if next.ID == r.ID {
		t.Fatal("reused operation identity")
	}
	if !b.Complete(Result{ID: next.ID, Value: json.RawMessage(`true`)}) {
		t.Fatal("missing request")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
