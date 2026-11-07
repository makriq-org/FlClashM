package main

import (
	"testing"
	"time"
)

func TestConnectionResetCompletesAndInvalidatesDiagnostics(t *testing.T) {
	before, _ := routeStamp()
	done := make(chan bool, 1)
	go func() { done <- handleResetConnections() }()
	select {
	case ok := <-done:
		after, _ := routeStamp()
		if !ok || after <= before {
			t.Fatalf("reset failed to invalidate diagnostics: %v, epoch %d -> %d", ok, before, after)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("reset deadlocked on the adapter's shared runLock/selectMu")
	}
}
