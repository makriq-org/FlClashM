package backend

import (
	"context"
	"errors"
	"time"
)

func (c *runtimeCoordinator) activateNodeLoop(epoch uint64) {
	if c.nodeOptions == nil || len(c.nodeOrder) == 0 {
		return
	}
	c.mu.Lock()
	if c.epoch != epoch || c.closed || c.document.Applied == nil || !c.document.Applied.Running || !c.document.Desired.Running || c.observed.State != "running" {
		c.mu.Unlock()
		return
	}
	if c.nodeCancel != nil {
		c.nodeCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.nodeCancel = cancel
	c.nodeContext = ctx
	c.mu.Unlock()
	if c.nodeOptions.ManualTicks {
		return
	}
	go func() {
		for {
			if err := c.wait(ctx, c.nextNodeDelay()); err != nil {
				return
			}
			if err := (&Backend{c}).ReconcileNodes(ctx); err != nil && ctx.Err() != nil {
				return
			}
		}
	}()
}

// ReconcileNodes is driven by the backend timer or the host's OS-event queue.
// It does not accept a plan or runtime state from an attached UI.
func (b *Backend) ReconcileNodes(ctx context.Context) error {
	c := b.coordinator
	c.commands.Lock()
	defer c.commands.Unlock()
	c.mu.Lock()
	generation := c.epoch
	lifetime := c.nodeContext
	allowed := !c.closed && c.nodeOptions != nil && c.document.Applied != nil && c.document.Applied.Running && c.document.Desired.Running && c.active == nil
	c.mu.Unlock()
	if !allowed || lifetime == nil {
		return nil
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	detach := context.AfterFunc(lifetime, cancel)
	defer detach()
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, id := range c.nodeOrder {
		node := c.nodes[id]
		if node.awake {
			if err := c.observeNode(ctx, node); err != nil && ctx.Err() != nil {
				return ctx.Err()
			}
		}
		if node.pending {
			if err := c.nodeOperation(ctx, node.plan.ID, "node.strategy", func(operation context.Context) error { return c.continueSelection(operation, node, generation) }); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				node.pending = false
			}
		}
		if activation := node.plan.Activation; activation != nil && activation.Mode == "auto" && !c.now().Before(node.nextCheck) {
			node.nextCheck = c.now().Add(time.Duration(activation.Wake.Interval) * time.Second)
			if err := c.reconcileReserve(ctx, node, generation); err != nil && ctx.Err() != nil {
				return ctx.Err()
			}
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	c.publishNodes(generation)
	return nil
}
func (c *runtimeCoordinator) reconcileReserve(ctx context.Context, node *nodeRuntime, generation uint64) error {
	activation := node.plan.Activation
	now := c.now()
	if now.Before(node.retryUntil) {
		return nil
	}
	if !node.awake {
		hasNetwork, err := c.nodeOptions.Inspection.HasNetwork(ctx)
		if err != nil || !hasNetwork {
			node.failures = 0
			return err
		}
		healthy, err := c.nodeOptions.Inspection.TestGroup(ctx, activation.WatchGroup, activation.Wake.URLs)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err == nil && healthy {
			node.failures = 0
			return nil
		}
		node.failures++
		if node.failures < activation.Wake.Failures {
			return nil
		}
		return c.nodeOperation(ctx, node.plan.ID, "node.wake", func(operation context.Context) error {
			wakeErr := c.launchNode(operation, node)
			if wakeErr == nil {
				healthy, checkErr := c.nodeOptions.Inspection.TestGroup(operation, node.plan.Name, activation.Wake.URLs)
				if checkErr == nil && healthy {
					node.failures = 0
					node.timeIdle = time.Time{}
					wakeErr = c.commitNodeState(generation)
					if wakeErr == nil {
						return nil
					}
				} else {
					wakeErr = errors.Join(checkErr, errors.New("node wake connectivity failed"))
				}
			}
			cleanup, done := context.WithTimeout(context.Background(), c.cleanupTimeout)
			defer done()
			stopErr := c.nodeOptions.Adapter.Stop(cleanup, node.plan.ID)
			node.awake = false
			node.observed = "sleeping"
			if stopErr != nil {
				node.observed = "unknown"
			}
			node.retryUntil = c.now().Add(time.Duration(activation.Wake.RetryAfter) * time.Second)
			node.nextCheck = node.retryUntil
			return errors.Join(wakeErr, stopErr)
		})
	}
	if activation.Sleep.Idle == 0 {
		return nil
	}
	chains, err := c.nodeOptions.Inspection.Connections(ctx)
	if err != nil {
		node.timeIdle = time.Time{}
		return err
	}
	selected, err := c.nodeOptions.Inspection.Selected(ctx, activation.ContainingGroups)
	if err != nil {
		node.timeIdle = time.Time{}
		return err
	}
	for _, chain := range chains {
		for _, name := range chain {
			if name == node.plan.Name {
				node.timeIdle = time.Time{}
				return nil
			}
		}
	}
	for _, group := range activation.ContainingGroups {
		value, ok := selected[group]
		if !ok {
			node.timeIdle = time.Time{}
			return errors.New("group selection observation unavailable")
		}
		if value == node.plan.Name {
			node.timeIdle = time.Time{}
			return nil
		}
	}
	if node.timeIdle.IsZero() {
		node.timeIdle = now
		return nil
	}
	if now.Sub(node.timeIdle) < time.Duration(activation.Sleep.Idle)*time.Second {
		return nil
	}
	return c.nodeOperation(ctx, node.plan.ID, "node.sleep", func(operation context.Context) error {
		if err := c.nodeOptions.Adapter.Stop(operation, node.plan.ID); err != nil {
			return err
		}
		node.awake = false
		node.observed = "sleeping"
		if err := c.commitNodeState(generation); err != nil {
			node.awake = true
			var restoreErr error
			if c.nodeGenerationCurrent(generation) {
				cleanup, done := context.WithTimeout(context.Background(), c.cleanupTimeout)
				defer done()
				restoreErr = c.launchNode(cleanup, node)
			}
			return errors.Join(err, restoreErr)
		}
		return nil
	})
}
func (c *runtimeCoordinator) commitNodeState(generation uint64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.epoch != generation || c.closed || c.document.Applied == nil || !c.document.Desired.Running {
		return ErrSuperseded
	}
	next := cloneDocument(c.document)
	next.Applied.Nodes = c.persistedNodes()
	if e := c.nodeMutation; e != nil {
		if e.ctx.Err() != nil {
			return e.ctx.Err()
		}
		if next.Pending == nil || next.Pending.OperationID != e.receipt.OperationID {
			return ErrSuperseded
		}
		receipt := e.receipt
		receipt.Status = "succeeded"
		next.Receipts = appendReceipt(next.Receipts, receipt)
		next.Pending = nil
	}
	err := c.saveLocked(next)
	if err == nil && c.nodeMutation != nil {
		c.nodeMutation.receipt.Status = "succeeded"
	}
	return err
}

func (c *runtimeCoordinator) nextNodeDelay() time.Duration {
	c.commands.Lock()
	defer c.commands.Unlock()
	delay := 30 * time.Second
	now := c.now()
	for _, node := range c.nodes {
		if node.pending {
			return 0
		}
		if node.awake {
			for _, due := range []time.Time{node.nextObservation, node.nextOptional} {
				if due.IsZero() {
					continue
				}
				if due == node.nextOptional && !node.optionalPending {
					continue
				}
				remaining := due.Sub(now)
				if remaining < 0 {
					remaining = 0
				}
				if remaining < delay {
					delay = remaining
				}
			}
		}

		if node.plan.Activation != nil && node.plan.Activation.Mode == "auto" {
			remaining := node.nextCheck.Sub(now)
			if remaining < 0 {
				remaining = 0
			}
			if remaining < delay {
				delay = remaining
			}
		}
	}
	return delay
}

func (c *runtimeCoordinator) nodeGenerationCurrent(generation uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.closed && c.epoch == generation && c.document.Desired.Running
}

func (c *runtimeCoordinator) observeNode(ctx context.Context, node *nodeRuntime) error {
	now := c.now()
	if !now.Before(node.nextObservation) {
		node.nextObservation = now.Add(30 * time.Second)
		observation, err := c.nodeOptions.Adapter.Observe(ctx, node.plan.ID)
		if err != nil {
			node.observed = "unknown"
			return err
		}
		if observation.State == "running" && node.observed == "starting" {
			listening, listenErr := c.nodeOptions.Adapter.Listening(ctx, node.plan)
			if listenErr != nil {
				node.nextObservation = now.Add(time.Second)
				return listenErr
			}
			if listening {
				node.observed = "running"
			} else if now.Before(node.optionalDeadline) {
				node.nextObservation = now.Add(time.Second)
				return nil
			} else {
				observation.State = "degraded"
			}
		}
		if observation.State != "running" {
			node.observed = observation.State
			if now.Before(node.retryUntil) {
				return nil
			}
			_ = c.nodeOptions.Adapter.Stop(ctx, node.plan.ID)
			if err = c.launchNode(ctx, node); err != nil {
				node.observed = "degraded"
				// Transient provider/handshake failures must not strand a selected
				// node for five minutes. Bound retries with exponential backoff.
				node.restartFailures++
				delay := time.Second * time.Duration(min(30, 1<<min(node.restartFailures-1, 5)))
				node.retryUntil = c.now().Add(delay)
				node.nextObservation = node.retryUntil
				return err
			}
		}
	}
	if !node.optionalPending || now.Before(node.nextOptional) {
		return nil
	}
	if !now.Before(node.optionalDeadline) {
		node.optionalPending = false
		node.connectivity = "failed"
		return nil
	}
	check := node.plan.Check
	budget := min(node.optionalDeadline.Sub(now), time.Duration(check.Timeout)*time.Second)
	if budget <= 0 {
		budget = time.Second
	}
	probeCtx, cancel := context.WithTimeout(ctx, budget)
	passed, err := c.checkNode(probeCtx, node.plan, check)
	cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if passed {
		node.optionalPending = false
		node.connectivity = "passed"
		return nil
	}
	retry := time.Duration(check.RetryInterval) * time.Second
	if retry <= 0 {
		retry = time.Second
	}
	node.nextOptional = c.now().Add(retry)
	if !c.now().Before(node.optionalDeadline) {
		node.optionalPending = false
		node.connectivity = "failed"
	}
	return err
}
