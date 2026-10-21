// Package host implements an asynchronous mechanism boundary. Requests belong
// to the service process, independently of any UI connection.
package host

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"sync"
	"sync/atomic"
)

type Request struct {
	ID     string `json:"id"`
	Method string `json:"method"`
	Input  any    `json:"input,omitempty"`
}
type Result struct {
	ID    string          `json:"id"`
	Value json.RawMessage `json:"value"`
	Error string          `json:"error,omitempty"`
}
type Broker struct {
	Send     func(Request)
	sequence atomic.Uint64
	mu       sync.Mutex
	pending  map[string]chan Result
}

func (b *Broker) Call(ctx context.Context, method string, input, out any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	id := strconv.FormatUint(b.sequence.Add(1), 10)
	result := make(chan Result, 1)
	b.mu.Lock()
	if b.pending == nil {
		b.pending = make(map[string]chan Result)
	}
	if len(b.pending) >= 64 {
		b.mu.Unlock()
		return errors.New("platform request limit reached")
	}
	b.pending[id] = result
	b.mu.Unlock()
	defer func() { b.mu.Lock(); delete(b.pending, id); b.mu.Unlock() }()
	b.Send(Request{ID: id, Method: method, Input: input})
	select {
	case <-ctx.Done():
		// The host must also fence cancelled service starts; cancellation never
		// relies on delivery to the Flutter process.
		b.Send(Request{ID: id, Method: "request.cancel"})
		return ctx.Err()
	case r := <-result:
		if r.Error != "" {
			return errors.New(r.Error)
		}
		if out == nil {
			return nil
		}
		return json.Unmarshal(r.Value, out)
	}
}
func (b *Broker) Complete(r Result) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	ch := b.pending[r.ID]
	if ch == nil {
		return false
	}
	select {
	case ch <- r:
		return true
	default:
		return false
	}
}
