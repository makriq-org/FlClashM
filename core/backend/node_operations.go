package backend

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
)

// Autonomous mutations share the coordinator's durable journal and operation
// namespace. Their generation identifies the current plan, while the unique ID
// identifies each wake/sleep/selection attempt within that generation.
func (c *runtimeCoordinator) nodeOperation(ctx context.Context, nodeID, method string, perform func(context.Context) error) error {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	id := "node-" + hex.EncodeToString(nonce)
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	c.mu.Lock()
	if c.closed || c.active != nil || !c.document.Desired.Running {
		c.mu.Unlock()
		return ErrSuperseded
	}
	generation := c.epoch
	fingerprintData, _ := json.Marshal([]any{method, nodeID, generation})
	hash := sha256.Sum256(fingerprintData)
	fingerprint := hex.EncodeToString(hash[:])
	e := &execution{ctx: child, cancel: cancel, done: make(chan struct{}), epoch: generation, receipt: Receipt{OperationID: id, Fingerprint: fingerprint, Method: method, Status: "accepted", Generation: generation}}
	next := cloneDocument(c.document)
	next.Pending = &Pending{Fingerprint: fingerprint, OperationID: id, Method: method, Generation: generation, NodeID: nodeID}
	next.Receipts = appendReceipt(next.Receipts, e.receipt)
	if err := c.saveLocked(next); err != nil {
		c.mu.Unlock()
		return err
	}
	c.executions[id] = e
	c.nodeMutation = e
	c.publishLocked()
	c.mu.Unlock()
	err := perform(child)
	if err == nil {
		c.mu.Lock()
		committed := e.receipt.Status == "succeeded"
		c.mu.Unlock()
		if !committed {
			err = c.commitNodeState(generation)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nodeMutation = nil
	e.err = err
	e.receipt.Status = "succeeded"
	if err != nil {
		e.receipt.Status = "failed"
		e.receipt.Error = "node operation failed"
		if child.Err() != nil || errors.Is(err, ErrSuperseded) {
			e.receipt.Status = "cancelled"
			e.receipt.Error = "node operation cancelled"
		}
		next := cloneDocument(c.document)
		next.Receipts = appendReceipt(next.Receipts, e.receipt)
		// Keep failed node intent for crash diagnostics; recovery always executes the
		// committed plan and its node states, never this unacknowledged mutation.
		if saveErr := c.saveLocked(next); saveErr != nil {
			e.err = errors.Join(err, saveErr)
		}
	}
	c.publishLocked()
	close(e.done)
	if len(c.executions) > 128 {
		for key, old := range c.executions {
			if old != e && old.receipt.Status != "accepted" {
				delete(c.executions, key)
				break
			}
		}
	}
	return e.err
}
