package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
)

// SubmitEngineCommand queues an effect at the current generation without
// superseding an accepted plan change. A later runtime command fences it.
func (b *Backend) SubmitEngineCommand(id string, command EngineCommand) (Receipt, error) {
	if _, ok := b.coordinator.engine.(EngineCommandAdapter); !ok {
		return Receipt{}, errors.New("engine commands are unavailable")
	}
	if command.Method == "" || len(command.Method) > 128 || len(command.Params) > MaxRequestBytes {
		return Receipt{}, errors.New("invalid engine command")
	}
	input, err := json.Marshal(command)
	if err != nil {
		return Receipt{}, err
	}
	r := Request{APIVersion: APIVersion, OperationID: id, Method: "engine.command", Input: input}
	fp, err := fingerprint(r)
	if err != nil {
		return Receipt{}, err
	}
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Receipt{}, ErrClosed
	}
	if e := c.executions[id]; e != nil {
		if e.fingerprint != fp {
			return Receipt{}, errors.New("operationId reused for a different command")
		}
		return e.receipt, nil
	}
	for _, receipt := range c.document.Receipts {
		if receipt.OperationID == id {
			if receipt.Fingerprint != fp {
				return Receipt{}, errors.New("operationId reused for a different command")
			}
			return receipt, nil
		}
	}
	pending := 0
	for _, e := range c.executions {
		if e.receipt.Status == "accepted" {
			pending++
		}
	}
	if pending >= 8 {
		return Receipt{}, errors.New("backend command queue is full")
	}
	receipt := Receipt{OperationID: id, Fingerprint: fp, Method: r.Method, Status: "accepted", Generation: c.epoch}
	next := cloneDocument(c.document)
	next.Receipts = appendReceipt(next.Receipts, receipt)
	if err = c.saveLocked(next); err != nil {
		return Receipt{}, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	e := &execution{request: r, fingerprint: fp, epoch: c.epoch, ctx: ctx, cancel: cancel, done: make(chan struct{}), receipt: receipt}
	c.executions[id] = e
	command.Params = bytes.Clone(command.Params)
	go c.executeEngineCommand(e, command)
	return receipt, nil
}
func (c *runtimeCoordinator) executeEngineCommand(e *execution, command EngineCommand) {
	c.commands.Lock()
	defer c.commands.Unlock()
	defer e.cancel()
	err := c.current(e)
	if err == nil {
		c.mu.Lock()
		if c.epoch != e.epoch || e.ctx.Err() != nil {
			err = ErrSuperseded
		} else {
			next := cloneDocument(c.document)
			next.Pending = &Pending{Fingerprint: e.fingerprint, OperationID: e.receipt.OperationID, Method: e.request.Method, Generation: e.epoch}
			err = c.saveLocked(next)
		}
		c.mu.Unlock()
	}
	if err == nil {
		if command.Method == "platform.event" || command.Method == "platform.tick" {
			err = c.platformCommand(e.ctx, command)
		} else {
			err = c.engine.(EngineCommandAdapter).Command(e.ctx, command)
		}
	}
	if err == nil {
		err = c.current(e)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e.err = err
	e.receipt.Status = "succeeded"
	if err != nil {
		e.receipt.Status = "failed"
		e.receipt.Error = "engine command failed"
		if e.ctx.Err() != nil || errors.Is(err, ErrSuperseded) || errors.Is(err, ErrClosed) {
			e.receipt.Status = "cancelled"
			e.receipt.Error = "engine command cancelled"
		}
	}
	next := cloneDocument(c.document)
	if err == nil && next.Pending != nil && next.Pending.OperationID == e.receipt.OperationID {
		next.Pending = nil
	}
	next.Receipts = appendReceipt(next.Receipts, e.receipt)
	if saveErr := c.saveLocked(next); saveErr != nil {
		e.err = errors.Join(err, saveErr)
		e.receipt.Status = "failed"
		e.receipt.Error = "storage commit failed"
	}
	e.request.Input = nil
	c.publishLocked()
	close(e.done)
	if len(c.executions) > 128 {
		for id, old := range c.executions {
			if old != e && old.receipt.Status != "accepted" {
				delete(c.executions, id)
				break
			}
		}
	}
}
