package backend

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"
)

var ErrSuperseded = errors.New("operation superseded")
var ErrClosed = errors.New("backend closed")

type Request struct {
	APIVersion  int    `json:"apiVersion"`
	OperationID string `json:"operationId"`
	Method      string `json:"method"` // apply, start, stop, recover
	Input       Input  `json:"params,omitempty"`
}
type Snapshot struct {
	InstanceID        string      `json:"instanceId"`
	APIVersion        int         `json:"apiVersion"`
	Sequence          uint64      `json:"seq"`
	Generation        uint64      `json:"generation"`
	AppliedGeneration uint64      `json:"appliedGeneration"`
	DesiredRunning    bool        `json:"desiredRunning"`
	AppliedRunning    bool        `json:"appliedRunning"`
	Observed          Observation `json:"observed"`
	OperationID       string      `json:"operationId,omitempty"`
	StartedAt         int64       `json:"startedAt,omitempty"`
}
type Event struct {
	Snapshot       Snapshot `json:"snapshot"`
	ResyncRequired bool     `json:"resyncRequired,omitempty"`
}
type execution struct {
	request     Request
	fingerprint string
	epoch       uint64
	cancel      context.CancelFunc
	ctx         context.Context
	done        chan struct{}
	receipt     Receipt
	err         error
}

// RuntimeCoordinator is private to Backend. Only this owner may invoke mutating
// adapter methods. The command lock fences side effects, the state lock protects
// snapshots/acceptance, and epochs fence results from non-cooperative adapters.
type runtimeCoordinator struct {
	compileSlots   chan struct{}
	instanceID     string
	commands       sync.Mutex
	mu             sync.Mutex
	compiler       Compiler
	engine         EngineAdapter
	transports     TransportAdapter
	platform       PlatformAdapter
	store          Store
	document       Document
	observed       Observation
	startedAt      int64
	epoch          uint64
	closed         bool
	active         *execution
	executions     map[string]*execution
	subscribers    map[uint64]chan Event
	subscriberID   uint64
	cleanupTimeout time.Duration
}

type Backend struct{ coordinator *runtimeCoordinator }

func Open(store Store, compiler Compiler, engine EngineAdapter, transports TransportAdapter, platform PlatformAdapter) (*Backend, error) {
	if store == nil || compiler == nil || engine == nil || transports == nil || platform == nil {
		return nil, errors.New("backend dependencies are required")
	}
	doc, err := store.Load()
	if errors.Is(err, ErrNoState) {
		doc, err = newDocument(), nil
	}
	if err != nil {
		return nil, err
	}
	if err = validateDocument(doc); err != nil {
		return nil, err
	}
	instance := make([]byte, 16)
	if _, err := rand.Read(instance); err != nil {
		return nil, err
	}
	c := &runtimeCoordinator{compileSlots: make(chan struct{}, 1), instanceID: hex.EncodeToString(instance), store: store, compiler: compiler, engine: engine, transports: transports, platform: platform,
		document: cloneDocument(doc), observed: Observation{State: "unknown"}, epoch: doc.Generation,
		executions: make(map[string]*execution), subscribers: make(map[uint64]chan Event), cleanupTimeout: 15 * time.Second}
	return &Backend{c}, nil
}

func (b *Backend) Snapshot() Snapshot {
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshotLocked()
}
func (c *runtimeCoordinator) snapshotLocked() Snapshot {
	s := Snapshot{InstanceID: c.instanceID, APIVersion: APIVersion, Sequence: c.document.Sequence, Generation: c.document.Generation,
		DesiredRunning: c.document.Desired.Running, Observed: c.observed, StartedAt: c.startedAt}
	if a := c.document.Applied; a != nil {
		s.AppliedGeneration = a.Plan.Generation
		s.AppliedRunning = a.Running
	}
	if p := c.document.Pending; p != nil {
		s.OperationID = p.OperationID
	}
	return s
}
func (c *runtimeCoordinator) publishLocked() {
	event := Event{Snapshot: c.snapshotLocked()}
	for _, ch := range c.subscribers {
		select {
		case ch <- event:
		default:
			// Never block the VPN on an absent/slow UI. Retain the latest snapshot and
			// tell it to resynchronize after any lost event, including repeated overflow.
			for len(ch) > 0 {
				<-ch
			}
			overflow := event
			overflow.ResyncRequired = true
			ch <- overflow
		}
	}
}

// Subscribe atomically captures the initial snapshot before later events. The
// cancel function only detaches the UI; it cannot stop or cancel backend work.
func (b *Backend) Subscribe(capacity int) (<-chan Event, func()) {
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	if capacity < 1 {
		capacity = 1
	}
	if capacity > 256 {
		capacity = 256
	}
	ch := make(chan Event, capacity)
	ch <- Event{Snapshot: c.snapshotLocked()}
	if c.closed {
		close(ch)
		return ch, func() {}
	}
	c.subscriberID++
	id := c.subscriberID
	c.subscribers[id] = ch
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			c.mu.Lock()
			defer c.mu.Unlock()
			if _, ok := c.subscribers[id]; ok {
				delete(c.subscribers, id)
				close(ch)
			}
		})
	}
}
func fingerprint(r Request) (string, error) {
	if r.APIVersion != APIVersion {
		return "", fmt.Errorf("unsupported API version %d", r.APIVersion)
	}
	if len(r.OperationID) < 1 || len(r.OperationID) > 128 {
		return "", errors.New("operationId must contain 1..128 bytes")
	}
	switch r.Method {
	case "apply":
		input, err := canonicalJSON(r.Input)
		if err != nil {
			return "", err
		}
		r.Input = input
	case "start", "stop", "recover":
		if len(r.Input) > 0 {
			return "", errors.New("method does not accept input")
		}
	default:
		return "", errors.New("unsupported backend method")
	}
	r.OperationID = ""
	raw, _ := json.Marshal(r)
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:]), nil
}

// Submit returns immediately. Operation contexts belong to the backend and are
// independent of any request, binder callback, Flutter engine or UI lifetime.
func (b *Backend) Submit(r Request) (Receipt, error) {
	fp, err := fingerprint(r)
	if err != nil {
		return Receipt{}, err
	}
	// Copy caller-owned input before the goroutine can observe it.
	r.Input = bytes.Clone(r.Input)
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Receipt{}, ErrClosed
	}
	if e := c.executions[r.OperationID]; e != nil {
		if e.fingerprint != fp {
			return Receipt{}, errors.New("operationId reused for a different command")
		}
		return e.receipt, nil
	}
	for _, receipt := range c.document.Receipts {
		if receipt.OperationID == r.OperationID {
			if receipt.Fingerprint != fp {
				return Receipt{}, errors.New("operationId reused for a different command")
			}
			return receipt, nil
		}
	}
	pending := 0
	for _, execution := range c.executions {
		if execution.receipt.Status == "accepted" {
			pending++
		}
	}
	if pending >= 8 {
		return Receipt{}, errors.New("backend command queue is full")
	}
	c.epoch++
	if c.active != nil {
		c.active.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	e := &execution{request: r, fingerprint: fp, epoch: c.epoch, ctx: ctx, cancel: cancel, done: make(chan struct{}),
		receipt: Receipt{OperationID: r.OperationID, Fingerprint: fp, Status: "accepted", Generation: c.epoch}}
	c.executions[r.OperationID] = e
	c.active = e
	go c.execute(e)
	return e.receipt, nil
}

// Await only cancels the wait, never the submitted operation. Explicit Cancel,
// Stop, or a newer command is required to change backend intent.
func (b *Backend) Await(ctx context.Context, id string) (Receipt, error) {
	c := b.coordinator
	c.mu.Lock()
	e := c.executions[id]
	if e == nil {
		for _, r := range c.document.Receipts {
			if r.OperationID == id {
				c.mu.Unlock()
				return r, nil
			}
		}
		c.mu.Unlock()
		return Receipt{}, errors.New("unknown operation")
	}
	done := e.done
	c.mu.Unlock()
	select {
	case <-ctx.Done():
		return Receipt{}, ctx.Err()
	case <-done:
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return e.receipt, e.err
}
func (b *Backend) Cancel(id string) bool {
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.executions[id]
	if e == nil || e.receipt.Status != "accepted" {
		return false
	}
	e.cancel()
	return true
}
func (c *runtimeCoordinator) current(e *execution) error {
	if err := e.ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ErrClosed
	}
	if c.epoch != e.epoch {
		return ErrSuperseded
	}
	return nil
}
func (c *runtimeCoordinator) saveLocked(next Document) error {
	next.Sequence = c.document.Sequence + 1
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.document = cloneDocument(next)
	return nil
}

func (c *runtimeCoordinator) execute(e *execution) {
	c.commands.Lock()
	defer c.commands.Unlock()
	defer e.cancel()
	err := c.current(e)
	if err == nil {
		err = c.perform(e)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e.err = err
	e.receipt.Status = "succeeded"
	if err != nil {
		e.receipt.Status = "failed"
		e.receipt.Error = "operation failed"
		if errors.Is(err, context.Canceled) || errors.Is(err, ErrSuperseded) || errors.Is(err, ErrClosed) {
			e.receipt.Status = "cancelled"
			e.receipt.Error = "operation cancelled"
		}
	}
	// A commit failure must leave the pending journal intact. A later recovery
	// uses it to fence any operation that was never durably acknowledged.
	// Successful receipt and applied generation were committed atomically by
	// perform. Failed receipts retain the journal for interrupted recovery.
	if err != nil {
		next := cloneDocument(c.document)
		if e.epoch > next.Generation {
			next.Generation = e.epoch
		}
		next.Receipts = appendReceipt(next.Receipts, e.receipt)
		if saveErr := c.saveLocked(next); saveErr != nil {
			e.err = errors.Join(e.err, saveErr)
			e.receipt.Status = "failed"
			e.receipt.Error = "storage commit failed"
		}
	}
	if c.active == e {
		c.active = nil
	}
	c.publishLocked()
	e.request.Input = nil
	close(e.done)
	// Only completed receipts need durability; avoid retaining unbounded requests.
	if len(c.executions) > 128 {
		for id, old := range c.executions {
			if old != e && old.receipt.Status != "accepted" {
				delete(c.executions, id)
				break
			}
		}
	}
}

func (c *runtimeCoordinator) perform(e *execution) error {
	c.mu.Lock()
	previous := cloneDocument(c.document)
	next := cloneDocument(c.document)
	next.Generation = e.epoch
	switch e.request.Method {
	case "apply":
		next.Desired.Input = bytes.Clone(e.request.Input)
	case "start":
		next.Desired.Running = true
	case "stop":
		next.Desired.Running = false
		if previous.Applied != nil {
			next.Desired.Input = bytes.Clone(previous.Applied.Input)
		}
	case "recover":
		// An interrupted switch may have saved a new desired input, but only the
		// committed generation is eligible for recovery. Explicit stop intent wins.
		if previous.Applied != nil {
			next.Desired.Input = bytes.Clone(previous.Applied.Input)
		} else {
			next.Desired = Desired{}
		}
	}
	if next.Desired.Running && len(next.Desired.Input) == 0 {
		c.mu.Unlock()
		return errors.New("no profile configured")
	}
	if previous.Pending != nil && previous.Pending.OperationID != e.request.OperationID {
		found := false
		for _, receipt := range next.Receipts {
			if receipt.OperationID == previous.Pending.OperationID {
				found = true
				break
			}
		}
		if !found {
			next.Receipts = appendReceipt(next.Receipts, Receipt{OperationID: previous.Pending.OperationID, Fingerprint: previous.Pending.Fingerprint, Generation: previous.Pending.Generation, Status: "interrupted", Error: "operation interrupted before commit"})
		}
	}
	next.Pending = &Pending{Fingerprint: e.fingerprint, OperationID: e.request.OperationID, Method: e.request.Method, Generation: e.epoch}
	if err := c.saveLocked(next); err != nil {
		c.mu.Unlock()
		return err
	}
	c.publishLocked()
	c.mu.Unlock()

	if e.request.Method == "stop" {
		err := c.cleanup()
		if err == nil {
			err = c.current(e)
		}
		if err != nil {
			return err
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.epoch != e.epoch || e.ctx.Err() != nil {
			return ErrSuperseded
		}
		committed := cloneDocument(c.document)
		if committed.Applied != nil {
			committed.Applied.Running = false
		}
		committed.Pending = nil
		committed.Receipts = appendReceipt(committed.Receipts, Receipt{OperationID: e.request.OperationID, Fingerprint: e.fingerprint, Status: "succeeded", Generation: e.epoch})
		return c.saveLocked(committed)
	}
	var plan *RuntimePlan
	var err error
	if len(next.Desired.Input) > 0 {
		plan, err = c.compile(e.ctx, bytes.Clone(next.Desired.Input), e.epoch)
		if err == nil && (plan == nil || plan.Generation() != e.epoch) {
			err = errors.New("compiler returned invalid generation")
		}
	}
	if err == nil {
		err = c.current(e)
	}
	touched := false
	if err == nil {
		touched = true
		err = c.install(e, plan, next.Desired.Running)
	}
	if err == nil {
		c.mu.Lock()
		// The epoch and commit are checked under the same lock as command acceptance.
		if c.epoch != e.epoch || e.ctx.Err() != nil {
			err = ErrSuperseded
		} else {
			committed := cloneDocument(c.document)
			if plan != nil {
				committed.Applied = &Applied{Plan: plan.Data(), Input: bytes.Clone(next.Desired.Input), Running: next.Desired.Running}
			}
			committed.Pending = nil
			committed.Receipts = appendReceipt(committed.Receipts, Receipt{OperationID: e.request.OperationID, Fingerprint: e.fingerprint, Status: "succeeded", Generation: e.epoch})
			err = c.saveLocked(committed)
		}
		c.mu.Unlock()
	}
	if err != nil {
		var rollbackErr error
		if touched {
			rollbackErr = c.rollback(e, previous)
		}
		c.mu.Lock()
		if e.ctx.Err() != nil && c.epoch == e.epoch && !c.closed {
			restored := cloneDocument(c.document)
			restored.Desired = previous.Desired
			rollbackErr = errors.Join(rollbackErr, c.saveLocked(restored))
		}
		if rollbackErr != nil {
			c.observed = Observation{State: "degraded", Message: "runtime rollback failed"}
		}
		// Keep the failed intent and journal until a subsequent durable command;
		// recovery can distinguish it from a successful switch after process death.
		c.mu.Unlock()
		return errors.Join(err, rollbackErr)
	}
	return nil
}

func (c *runtimeCoordinator) install(e *execution, plan *RuntimePlan, running bool) error {
	if err := c.cleanup(); err != nil {
		return err
	}
	if err := c.current(e); err != nil {
		return err
	}
	if plan != nil {
		for _, step := range []func() error{
			func() error { return c.transports.Prepare(e.ctx, plan) },
			func() error { return c.transports.Start(e.ctx, plan) },
			func() error { return c.engine.Apply(e.ctx, plan) },
		} {
			if err := step(); err != nil {
				return err
			}
			if err := c.current(e); err != nil {
				return err
			}
		}
	}
	if running {
		if err := c.engine.Start(e.ctx); err != nil {
			return err
		}
		if err := c.current(e); err != nil {
			return err
		}
		if err := c.platform.Start(e.ctx, plan); err != nil {
			return err
		}
		if err := c.current(e); err != nil {
			return err
		}
	} else {
		// Plan preparation while stopped must not keep external nodes alive.
		if err := c.transports.Stop(e.ctx); err != nil {
			return err
		}
	}
	return c.observe(e.ctx, running)
}
func (c *runtimeCoordinator) cleanup() error {
	ctx, cancel := context.WithTimeout(context.Background(), c.cleanupTimeout)
	defer cancel()
	// Run every cleanup step even if an earlier adapter fails.
	platformErr := c.platform.Stop(ctx)
	engineErr := c.engine.Stop(ctx)
	transportErr := c.transports.Stop(ctx)
	c.mu.Lock()
	c.startedAt = 0
	c.observed = Observation{State: "stopped"}
	if platformErr != nil || engineErr != nil || transportErr != nil {
		c.observed = Observation{State: "unknown", Message: "runtime cleanup failed"}
	}
	c.mu.Unlock()
	return errors.Join(platformErr, engineErr, transportErr)
}
func (c *runtimeCoordinator) observe(ctx context.Context, running bool) error {
	expected := "stopped"
	if running {
		expected = "running"
	}
	for _, read := range []func(context.Context) (Observation, error){c.engine.Observe, c.transports.Observe, c.platform.Observe} {
		observation, err := read(ctx)
		if err != nil {
			return err
		}
		if observation.State != expected {
			return fmt.Errorf("runtime observed %s, expected %s", observation.State, expected)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.observed = Observation{State: expected}
	if running {
		c.startedAt = time.Now().UnixMilli()
	}
	return nil
}
func (c *runtimeCoordinator) rollback(e *execution, previous Document) error {
	if err := c.cleanup(); err != nil {
		return err
	}
	// Supersession requires cleanup, but must not restart after a newer Stop.
	// Explicit cancellation without a replacement restores the previous plan.
	c.mu.Lock()
	superseded := c.epoch != e.epoch || c.closed
	c.mu.Unlock()
	if superseded {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cleanupTimeout)
	defer cancel()
	rollback := &execution{ctx: ctx, epoch: e.epoch}
	if previous.Applied == nil {
		return nil
	}
	plan, err := RestorePlan(previous.Applied.Plan)
	if err != nil {
		return err
	}
	return c.install(rollback, plan, previous.Applied.Running)
}

// Close is process teardown, not user Stop: persisted desired intent survives.
func (b *Backend) Close() error {
	c := b.coordinator
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	if c.active != nil {
		c.active.cancel()
	}
	c.mu.Unlock()
	c.commands.Lock()
	defer c.commands.Unlock()
	err := c.cleanup()
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, ch := range c.subscribers {
		close(ch)
		delete(c.subscribers, id)
	}
	return err
}

func appendReceipt(receipts []Receipt, receipt Receipt) []Receipt {
	receipts = append(receipts, receipt)
	if len(receipts) > 128 {
		receipts = receipts[len(receipts)-128:]
	}
	return receipts
}

// Preparation has no runtime side effects. A non-cooperative parser must not
// block Stop; its late result is discarded, while a single slot bounds retained
// inputs and prevents parallel use of an engine parser with shared caches.
func (c *runtimeCoordinator) compile(ctx context.Context, input Input, generation uint64) (*RuntimePlan, error) {
	select {
	case c.compileSlots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	type result struct {
		plan *RuntimePlan
		err  error
	}
	done := make(chan result, 1)
	go func() {
		defer func() { <-c.compileSlots }()
		plan, err := c.compiler.Compile(ctx, input, generation)
		done <- result{plan, err}
	}()
	select {
	case outcome := <-done:
		return outcome.plan, outcome.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
