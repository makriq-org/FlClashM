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
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
)

var ErrSuperseded = errors.New("operation superseded")
var ErrClosed = errors.New("backend closed")

// Receipt.ErrorCode and APIError.ErrorCode carry one of these stable machine
// values; Error/Message stay short human-readable text that clients must not
// parse. A successful receipt has no code.
const (
	// ErrorCodeSuperseded: a newer runtime command (including Stop or an OS
	// revocation) took over before this operation completed. It is not a fault.
	ErrorCodeSuperseded = "superseded"
	// ErrorCodeCancelled: explicit operation.cancel without a newer command.
	ErrorCodeCancelled = "cancelled"
	// ErrorCodeClosed: backend/process teardown interrupted the operation.
	ErrorCodeClosed = "closed"
	// ErrorCodeFailed: the operation itself failed; Error names the cause.
	ErrorCodeFailed = "failed"
)

type Request struct {
	APIVersion  int    `json:"apiVersion"`
	OperationID string `json:"operationId"`
	Method      string `json:"method"` // apply, start, stop, recover
	Input       Input  `json:"params,omitempty"`
}
type Snapshot struct {
	InstanceID        string         `json:"instanceId"`
	APIVersion        int            `json:"apiVersion"`
	Sequence          uint64         `json:"seq"`
	Nodes             []NodeSnapshot `json:"nodes,omitempty"`
	Generation        uint64         `json:"generation"`
	AppliedGeneration uint64         `json:"appliedGeneration"`
	DesiredRunning    bool           `json:"desiredRunning"`
	AppliedRunning    bool           `json:"appliedRunning"`
	Observed          Observation    `json:"observed"`
	OperationID       string         `json:"operationId,omitempty"`
	StartedAt         int64          `json:"startedAt,omitempty"`
}
type Event struct {
	Snapshot       Snapshot `json:"snapshot"`
	ResyncRequired bool     `json:"resyncRequired,omitempty"`
}
type execution struct {
	request      Request
	fingerprint  string
	epoch        uint64
	cancel       context.CancelFunc
	ctx          context.Context
	done         chan struct{}
	receipt      Receipt
	priorDesired Desired
	err          error
	// internal marks coordinator-owned platform effects. They are retried by
	// the policy, so they are neither journaled nor kept in receipt history.
	internal bool
}

// RuntimeCoordinator is private to Backend. Only this owner may invoke mutating
// adapter methods. The command lock fences side effects, the state lock protects
// snapshots/acceptance, and epochs fence results from non-cooperative adapters.
type runtimeCoordinator struct {
	policy         *platformPolicy
	compileSlots   chan struct{}
	eventSequence  uint64
	nodeOptions    *NodeOptions
	nodes          map[string]*nodeRuntime
	nodeOrder      []string
	nodeSnapshot   []NodeSnapshot
	nodeCancel     context.CancelFunc
	nodeContext    context.Context
	nodesExecuting bool
	keepNodesWarm  bool // UI preparation only; never persisted as a VPN intent.
	// uiDetached fences warm commands queued by a UI session that has gone
	// away; uiSequence orders UI attach/detach facts by API arrival.
	uiDetached bool
	uiSequence uint64
	// residentDigest names the plan whose engine configuration and prepared
	// nodes are resident in this process. It is cleared before any mechanism
	// may replace them and set only after they were installed completely, so
	// an interrupted install can never be mistaken for the committed plan.
	// Guarded by the command lock.
	residentDigest string
	// nodesDigest names the plan of the last completed node preparation.
	nodesDigest    string
	nodeMutation   *execution
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

// PrepareForUI records a local UI-session fact, not a durable run intent. All
// resource effects remain in the coordinator's serialized commands.
func (b *Backend) PrepareForUI() error { return b.SetUISession(true, 0) }

// ReleaseUI records that no UI remains attached. It is idempotent.
func (b *Backend) ReleaseUI() error { return b.SetUISession(false, 0) }

// SetUISession records whether a UI is attached. A non-zero sequence orders
// facts by API arrival: an older fact applied late is ignored. Detaching never
// changes VPN intent; while the VPN is stopped it releases ordinary nodes that
// were kept only for latency checks, through the serialized command lock.
func (b *Backend) SetUISession(attached bool, sequence uint64) error {
	c := b.coordinator
	c.commands.Lock()
	defer c.commands.Unlock()
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return ErrClosed
	}
	if sequence != 0 {
		if sequence <= c.uiSequence {
			c.mu.Unlock()
			return nil
		}
		c.uiSequence = sequence
	}
	c.keepNodesWarm = attached
	c.uiDetached = !attached
	running := c.document.Desired.Running || (c.document.Applied != nil && c.document.Applied.Running)
	c.mu.Unlock()
	if attached || running || c.nodeOptions == nil || !c.nodesExecuting {
		// A running VPN keeps its nodes; a later Stop releases them because
		// the preparation lease is gone.
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cleanupTimeout)
	defer cancel()
	return c.transports.Stop(ctx)
}

func Open(store Store, compiler Compiler, engine EngineAdapter, transports TransportAdapter, platform PlatformAdapter, nodeOptions ...NodeOptions) (*Backend, error) {
	if store == nil || compiler == nil || engine == nil || (transports == nil && len(nodeOptions) != 1) || platform == nil {
		return nil, errors.New("backend dependencies are required")
	}
	if len(nodeOptions) > 1 {
		return nil, errors.New("one node host is required")
	}
	if len(nodeOptions) == 1 && (transports != nil || nodeOptions[0].Adapter == nil || nodeOptions[0].Inspection == nil || nodeOptions[0].Cache == nil) {
		return nil, errors.New("exclusive node host dependencies are required")
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
	orphaned := false
	if doc.Pending != nil {
		found := false
		for _, receipt := range doc.Receipts {
			found = found || receipt.OperationID == doc.Pending.OperationID
		}
		if !found {
			p := doc.Pending
			doc.Receipts = appendReceipt(doc.Receipts, Receipt{OperationID: p.OperationID, Fingerprint: p.Fingerprint, Generation: p.Generation, Status: "interrupted", Error: "operation interrupted before commit"})
			orphaned = true
		}
	}

	for i := range doc.Receipts {
		if doc.Receipts[i].Status == "accepted" {
			doc.Receipts[i].Status = "interrupted"
			doc.Receipts[i].Error = "operation interrupted before commit"
			orphaned = true
		}
	}
	if orphaned {
		doc.Sequence++
		if err = store.Save(doc); err != nil {
			return nil, err
		}
	}
	instance := make([]byte, 16)
	if _, err := rand.Read(instance); err != nil {
		return nil, err
	}
	c := &runtimeCoordinator{compileSlots: make(chan struct{}, 1), instanceID: hex.EncodeToString(instance), store: store, compiler: compiler, engine: engine, transports: transports, platform: platform,
		document: cloneDocument(doc), observed: Observation{State: "unknown"}, epoch: doc.Generation,
		executions: make(map[string]*execution), subscribers: make(map[uint64]chan Event), cleanupTimeout: 15 * time.Second}
	c.eventSequence = doc.Sequence
	if len(nodeOptions) == 1 {
		options := nodeOptions[0]
		c.nodeOptions = &options
		c.transports = coordinatedTransports{c}
		c.nodes = map[string]*nodeRuntime{}
	}
	c.openPlatformPolicy()
	return &Backend{c}, nil
}

func (b *Backend) Snapshot() Snapshot {
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshotLocked()
}
func (c *runtimeCoordinator) snapshotLocked() Snapshot {
	s := Snapshot{InstanceID: c.instanceID, APIVersion: APIVersion, Sequence: c.eventSequence, Nodes: append([]NodeSnapshot(nil), c.nodeSnapshot...), Generation: c.document.Generation,
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
	if c.policy != nil {
		select {
		case c.policy.wake <- struct{}{}:
		default:
		}
	}
	c.eventSequence++
	event := Event{Snapshot: c.snapshotLocked()}
	for _, ch := range c.subscribers {
		select {
		case ch <- event:
		default:
			// Never block the VPN on an absent/slow UI. Retain the latest snapshot and
			// tell it to resynchronize after any lost event, including repeated overflow.
		drain:
			for {
				select {
				case <-ch:
				default:
					break drain
				}
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
	case "apply", "connect", "restart", "warm", "engine.command":
		input, err := canonicalJSON(r.Input)
		if err != nil {
			return "", err
		}
		r.Input = input
	case "start", "stop", "recover", "forget":
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
	return b.submit(r, nil)
}

// SubmitAtGeneration rejects an observation-derived command if a newer user
// intent arrived while the host was being inspected.
func (b *Backend) SubmitAtGeneration(r Request, generation uint64) (Receipt, error) {
	return b.submit(r, &generation)
}

func (b *Backend) submit(r Request, expected *uint64) (Receipt, error) {
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
	if expected != nil && c.epoch != *expected {
		return Receipt{}, ErrSuperseded
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
		// A full queue still admits one Stop, including when an autonomous node
		// operation owns the executor. Further Stops cannot grow the backlog.
		stopPending := c.active != nil && c.active.request.Method == "stop"
		if r.Method != "stop" || stopPending {
			return Receipt{}, errors.New("backend command queue is full")
		}
	}
	nextEpoch := c.epoch + 1
	next := cloneDocument(c.document)
	priorDesired := next.Desired
	priorDesired.Input = bytes.Clone(priorDesired.Input)
	next.Generation = nextEpoch
	switch r.Method {
	case "apply", "connect", "restart", "warm":
		next.Desired.Input = bytes.Clone(r.Input)
		if r.Method == "connect" {
			next.Desired.Running = true
		}
	case "start":
		next.Desired.Running = true
	case "forget":
		next.Desired = Desired{}
		next.Applied = nil
	case "stop":
		next.Desired.Running = false
		if next.Applied != nil {
			next.Desired.Input = bytes.Clone(next.Applied.Input)
		}
	case "recover":
		if next.Applied != nil {
			next.Desired.Input = bytes.Clone(next.Applied.Input)
		} else {
			next.Desired = Desired{}
		}
	}
	if next.Desired.Running && len(next.Desired.Input) == 0 {
		return Receipt{}, errors.New("no profile configured")
	}
	receipt := Receipt{OperationID: r.OperationID, Fingerprint: fp, Method: r.Method, Status: "accepted", Generation: nextEpoch}
	next.Pending = &Pending{Fingerprint: fp, OperationID: r.OperationID, Method: r.Method, Generation: nextEpoch}
	next.Receipts = appendReceipt(next.Receipts, receipt)
	// Acceptance is durable before a request can detach or preempt its predecessor.
	// A later apply inherits a previously accepted Stop even before Stop executes.
	if err := c.saveLocked(next); err != nil {
		return Receipt{}, err
	}
	c.epoch = nextEpoch
	if c.nodeCancel != nil {
		c.nodeCancel()
		c.nodeCancel = nil
	}
	if c.active != nil {
		c.active.cancel()
	}
	for _, queued := range c.executions {
		if queued.request.Method == "engine.command" && queued.receipt.Status == "accepted" {
			queued.cancel()
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	e := &execution{request: r, fingerprint: fp, epoch: nextEpoch, ctx: ctx, cancel: cancel, done: make(chan struct{}), receipt: receipt, priorDesired: priorDesired}
	c.publishLocked()
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
	for _, receipt := range c.document.Receipts {
		if receipt.OperationID == id && receipt.Status != "accepted" {
			return false
		}
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
	next.Sequence = max(c.document.Sequence, c.eventSequence) + 1
	if err := c.store.Save(next); err != nil {
		return err
	}
	c.document = cloneDocument(next)
	c.eventSequence = next.Sequence
	return nil
}

func (c *runtimeCoordinator) execute(e *execution) {
	c.commands.Lock()
	defer c.commands.Unlock()
	defer e.cancel()
	err := c.current(e)
	if err == nil {
		c.mu.Lock()
		hold := c.document.Desired.Running
		c.mu.Unlock()
		if lifetime, ok := c.platform.(OperationLifetime); ok && hold {
			err = lifetime.BeginOperation(e.ctx, e.request.OperationID)
			defer func() {
				ctx, cancel := context.WithTimeout(context.Background(), c.cleanupTimeout)
				defer cancel()
				_ = lifetime.EndOperation(ctx, e.request.OperationID)
			}()
		}
	}
	performed := false
	if err == nil {
		performed = true
		err = c.perform(e)
	}
	c.activateNodeLoop(e.epoch)
	if err != nil && e.ctx.Err() == nil {
		if diagnostics, ok := c.engine.(RuntimeDiagnostics); ok {
			diagnostics.RuntimeFailure(e.request.Method, err)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err != nil && e.ctx.Err() != nil {
		err = errors.Join(err, e.ctx.Err())
	}
	e.err = err
	e.receipt.Status = "succeeded"
	if err != nil {
		e.receipt.Status, e.receipt.ErrorCode, e.receipt.Error = c.failureLocked(e, err)
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
		// Explicit cancellation without a newer command withdraws the intent
		// accepted at submission, also when the command was cancelled while
		// still queued (perform restores it only after it started). Reset has
		// already dropped Applied, and a Stop whose effects ran keeps its intent.
		if e.ctx.Err() != nil && c.epoch == e.epoch && !c.closed && e.request.Method != "forget" && (!performed || e.request.Method != "stop") {
			next.Desired = e.priorDesired
			next.Desired.Input = bytes.Clone(e.priorDesired.Input)
		}
		next.Receipts = appendReceipt(next.Receipts, e.receipt)
		if saveErr := c.saveLocked(next); saveErr != nil {
			e.err = errors.Join(e.err, saveErr)
			e.receipt.Status = "failed"
			e.receipt.ErrorCode = ErrorCodeFailed
			e.receipt.Error = "storage commit failed"
		}
	}
	if c.active == e {
		c.active = nil
	}
	c.publishLocked()
	e.request.Input = nil
	e.priorDesired.Input = nil
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
	if c.epoch != e.epoch || e.ctx.Err() != nil {
		c.mu.Unlock()
		return ErrSuperseded
	}
	previous := cloneDocument(c.document)
	previous.Desired = e.priorDesired
	next := cloneDocument(c.document)
	next.Generation = e.epoch
	switch e.request.Method {
	case "apply", "connect", "restart", "warm":
		next.Desired.Input = bytes.Clone(e.request.Input)
		if e.request.Method == "connect" {
			next.Desired.Running = true
		}
	case "start":
		next.Desired.Running = true
	case "forget":
		next.Desired = Desired{}
		next.Applied = nil
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
	if e.request.Method == "warm" {
		// A warm queued by a UI that detached meanwhile prepares the plan
		// like apply, but cannot recreate the preparation lease.
		if !c.uiDetached {
			c.keepNodesWarm = true
		}
	} else if e.request.Method == "forget" || (e.request.Method == "recover" && !next.Desired.Running) {
		c.keepNodesWarm = false
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

	if e.request.Method == "stop" || e.request.Method == "forget" {
		var err error
		if e.request.Method == "forget" {
			// Applied is gone and the engine configuration is erased below.
			c.residentDigest = ""
		}
		if e.request.Method == "stop" && c.keepNodesWarm && c.nodeOptions != nil && c.nodesExecuting {
			err = c.stopPreparedRuntime()
		} else {
			err = c.cleanup()
		}
		if err == nil && e.request.Method == "forget" {
			// Erasure waits for cancelled preparation to leave its cache files;
			// ordinary Stop still returns without waiting for a slow parser.
			wait, cancel := context.WithTimeout(e.ctx, 30*time.Second)
			select {
			case c.compileSlots <- struct{}{}:
				<-c.compileSlots
			case <-wait.Done():
				err = wait.Err()
			}
			cancel()
		}
		if err == nil && e.request.Method == "forget" {
			if eraser, ok := c.engine.(EngineEraser); ok {
				err = eraser.Forget(e.ctx)
			}
		}
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
			// Prepared nodes may belong to an interrupted install of another
			// plan; then the committed node states remain authoritative.
			if c.residentDigest == committed.Applied.Plan.Digest {
				committed.Applied.Nodes = c.persistedNodes()
			}
		}
		committed.Pending = nil
		committed.Receipts = appendReceipt(committed.Receipts, Receipt{OperationID: e.request.OperationID, Fingerprint: e.fingerprint, Method: e.request.Method, Status: "succeeded", Generation: e.epoch})
		return c.saveLocked(committed)
	}
	var plan *RuntimePlan
	var err error
	if len(next.Desired.Input) > 0 {
		if compiler, ok := c.compiler.(SelectionCompiler); ok && (e.request.Method == "apply" || e.request.Method == "warm" || e.request.Method == "connect") && previous.Applied != nil {
			old, restoreErr := RestorePlan(previous.Applied.Plan)
			if restoreErr != nil {
				err = restoreErr
			} else {
				plan, err = compiler.CompileSelection(e.ctx, next.Desired.Input, previous.Applied.Input, old, e.epoch)
			}
		}
		if err == nil && plan == nil {
			plan, err = c.compile(e.ctx, bytes.Clone(next.Desired.Input), e.epoch)
		}
		if err == nil && (plan == nil || plan.Generation() != e.epoch) {
			err = errors.New("compiler returned invalid generation")
		}
	}
	if err == nil {
		err = c.current(e)
	}
	touched := false
	if err == nil {
		_, hasSelection := c.engine.(SelectionAdapter)
		_, hasLiveSettings := c.engine.(LiveSettingsAdapter)
		samePlan := plan != nil && previous.Applied != nil && plan.Digest() == previous.Applied.Plan.Digest
		// In-place paths patch the resident engine and nodes. They are valid
		// only when those were installed for the committed plan in this process;
		// a superseded install may have left another plan's configuration.
		residentPlan := previous.Applied != nil && c.residentDigest == previous.Applied.Plan.Digest
		resident := residentPlan && previous.Applied.Running == next.Desired.Running && e.request.Method != "restart" && (samePlan || hasSelection || hasLiveSettings)
		if resident {
			c.mu.Lock()
			expected := "stopped"
			if next.Desired.Running {
				expected = "running"
			}
			resident = c.observed.State == expected
			c.mu.Unlock()
		}
		if resident {
			resident = c.observe(e.ctx, next.Desired.Running) == nil
		}
		if c.keepNodesWarm && !next.Desired.Running && !c.nodesExecuting {
			// A cancelled warm-up may leave a stopped engine but no processes.
			// Selection/settings shortcuts cannot complete that preparation.
			resident = false
		}
		// Persisted Applied describes the last commit, not an engine resident in
		// this process. Every in-place optimization requires fresh observations.
		unchanged := resident && samePlan && !(c.keepNodesWarm && !next.Desired.Running && !c.nodesExecuting)
		if err = c.current(e); err == nil && !unchanged {
			var patched bool
			var patchErr error
			if samePlan {
				patched, patchErr = c.tryPreparedTransition(e, previous, plan, next.Desired.Running)
			}
			if !patched && patchErr == nil && resident {
				patched, patchErr = c.trySelection(e, previous, plan, next.Desired.Running)
				if !patched && patchErr == nil {
					patched, patchErr = c.tryLiveSettings(e, previous, plan, next.Desired.Running)
				}
			}
			if patched {
				touched = true
				err = patchErr
			} else if patchErr != nil {
				err = patchErr
			} else {
				touched = true
				err = c.install(e, plan, next.Desired.Running)
			}
		}
	}
	if err == nil {
		c.mu.Lock()
		// The epoch and commit are checked under the same lock as command acceptance.
		if c.epoch != e.epoch || e.ctx.Err() != nil {
			err = ErrSuperseded
		} else {
			committed := cloneDocument(c.document)
			if plan != nil {
				committed.Applied = &Applied{Plan: plan.Data(), Input: bytes.Clone(next.Desired.Input), Running: next.Desired.Running, Nodes: c.persistedNodes()}
			}
			committed.Pending = nil
			committed.Receipts = appendReceipt(committed.Receipts, Receipt{OperationID: e.request.OperationID, Fingerprint: e.fingerprint, Method: e.request.Method, Status: "succeeded", Generation: e.epoch})
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
		// Preparation replaces node definitions and engine configuration; until
		// every step succeeded, neither belongs to any plan.
		c.residentDigest = ""
		steps := []func() error{func() error { return c.transports.Prepare(e.ctx, plan) }}
		if running || c.keepNodesWarm {
			steps = append(steps, func() error { return c.transports.Start(e.ctx, plan) })
		}
		steps = append(steps, func() error { return c.engine.Apply(e.ctx, plan) })
		for _, step := range steps {
			if err := step(); err != nil {
				return err
			}
			if err := c.current(e); err != nil {
				return err
			}
		}
		c.residentDigest = plan.Digest()
	}
	if running {
		if err := c.startRuntime(e, plan); err != nil {
			return err
		}
	} else if !c.keepNodesWarm {
		// Headless recovery after Stop never recreates a UI preparation lease.
		if err := c.transports.Stop(e.ctx); err != nil {
			return err
		}
	}
	return c.observe(e.ctx, running)
}

func (c *runtimeCoordinator) startRuntime(e *execution, plan *RuntimePlan) error {
	if err := c.engine.Start(e.ctx); err != nil {
		return err
	}
	if err := c.current(e); err != nil {
		return err
	}
	if err := c.platform.Start(e.ctx, plan); err != nil {
		return err
	}
	if err := c.platformStarted(e.ctx); err != nil {
		return err
	}
	return c.current(e)
}

// Stopping VPN pauses reserve automation, but ordinary prepared processes stay
// available for UI latency checks, as they did before the backend migration.
func (c *runtimeCoordinator) stopPreparedRuntime() error {
	ctx, cancel := context.WithTimeout(context.Background(), c.cleanupTimeout)
	defer cancel()
	platformErr := c.platform.Stop(ctx)
	engineErr := c.engine.Stop(ctx)
	var nodeErr error
	for _, node := range c.nodes {
		if node.plan.Activation != nil && node.plan.Activation.Mode == "auto" && node.awake {
			err := c.nodeOptions.Adapter.Stop(ctx, node.plan.ID)
			nodeErr = errors.Join(nodeErr, err)
			node.awake = false
			node.observed = "sleeping"
			if err != nil {
				node.observed = "unknown"
			}
		}
	}
	c.publishNodes()
	err := errors.Join(platformErr, engineErr, nodeErr)
	c.mu.Lock()
	c.startedAt = 0
	c.observed = Observation{State: "stopped"}
	if err != nil {
		c.observed = Observation{State: "unknown", Message: "runtime cleanup failed"}
	}
	c.mu.Unlock()
	return err
}
func (c *runtimeCoordinator) cleanup() error {
	c.mu.Lock()
	if c.nodeCancel != nil {
		c.nodeCancel()
		c.nodeCancel = nil
	}
	c.mu.Unlock()
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
	transportExpected := expected
	if !running && c.keepNodesWarm && c.nodesExecuting {
		// Prepared nodes are live even with VPN stopped. The execution flag is
		// intent, not evidence that their processes survived.
		transportExpected = "running"
	}
	readers := []struct {
		read     func(context.Context) (Observation, error)
		expected string
	}{
		{c.engine.Observe, expected},
		{c.transports.Observe, transportExpected},
		{c.platform.Observe, expected},
	}
	for _, read := range readers {
		observation, err := read.read(ctx)
		if err != nil {
			return err
		}
		if observation.State != read.expected {
			return fmt.Errorf("runtime observed %s, expected %s", observation.State, read.expected)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.observed = Observation{State: expected}
	if running && c.startedAt == 0 {
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
	if c.policy != nil {
		c.policy.cancel()
	}
	for _, e := range c.executions {
		if e.receipt.Status == "accepted" {
			e.cancel()
		}
	}
	if c.nodeCancel != nil {
		c.nodeCancel()
		c.nodeCancel = nil
	}
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

const maxReceipts = 128

// Autonomous receipts (OS recovery/revocation, reserve wake/sleep) share the
// history but may occupy only a few slots, so a persistently retried system
// operation cannot evict the outcome of a user command.
const maxSystemReceipts = 16

func systemReceipt(id string) bool {
	return strings.HasPrefix(id, "system-") || strings.HasPrefix(id, "node-")
}

func appendReceipt(receipts []Receipt, receipt Receipt) []Receipt {
	for i := range receipts {
		if receipts[i].OperationID == receipt.OperationID {
			receipts[i] = receipt
			return receipts
		}
	}
	receipts = append(receipts, receipt)
	if systemReceipt(receipt.OperationID) {
		count := 0
		for _, existing := range receipts {
			if systemReceipt(existing.OperationID) {
				count++
			}
		}
		for i := 0; count > maxSystemReceipts && i < len(receipts); {
			if systemReceipt(receipts[i].OperationID) {
				receipts = append(receipts[:i], receipts[i+1:]...)
				count--
				continue
			}
			i++
		}
	}
	if len(receipts) > maxReceipts {
		receipts = receipts[len(receipts)-maxReceipts:]
	}
	return receipts
}

const maxReceiptError = 300

var (
	receiptURLCredentials = regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@`)
	receiptSecretValues   = regexp.MustCompile(`(?i)(password|passwd|secret|token|uuid|private[-_]?key|pre-shared-key|psk|auth[a-z_-]*)(["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}\]]+)`)
)

// failureLocked classifies a failed execution for its receipt. Caller holds mu.
func (c *runtimeCoordinator) failureLocked(e *execution, err error) (status, code, message string) {
	switch {
	case c.closed || errors.Is(err, ErrClosed):
		code, message = ErrorCodeClosed, "backend closed"
	case c.epoch != e.epoch:
		code, message = ErrorCodeSuperseded, "operation superseded by a newer command"
	case e.ctx.Err() != nil || errors.Is(err, context.Canceled):
		code, message = ErrorCodeCancelled, "operation cancelled"
	case errors.Is(err, ErrSuperseded):
		code, message = ErrorCodeSuperseded, "operation superseded by a newer command"
	default:
		return "failed", ErrorCodeFailed, describeError(err)
	}
	return "cancelled", code, message
}

// ErrorCode maps an API rejection to a stable receipt error code.
func ErrorCode(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrClosed):
		return ErrorCodeClosed
	case errors.Is(err, ErrSuperseded):
		return ErrorCodeSuperseded
	case errors.Is(err, context.Canceled):
		return ErrorCodeCancelled
	}
	return ErrorCodeFailed
}

// describeError returns the first meaningful line of an error chain as short
// user-facing text. Joined rollback errors and cancellation markers follow the
// root cause; credentials embedded in URLs or key/value pairs are redacted.
// Full errors still reach the host's redacting RuntimeDiagnostics sink.
func describeError(err error) string {
	message := ""
	for _, line := range strings.Split(err.Error(), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line == context.Canceled.Error() || line == ErrSuperseded.Error() || line == ErrClosed.Error() {
			continue
		}
		message = line
		break
	}
	if message == "" {
		return "operation failed"
	}
	message = receiptURLCredentials.ReplaceAllString(message, "${1}***@")
	message = receiptSecretValues.ReplaceAllString(message, "${1}${2}***")
	message = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, message)
	if runes := []rune(message); len(runes) > maxReceiptError {
		message = string(runes[:maxReceiptError-1]) + "…"
	}
	return message
}

// Preparation has no runtime side effects. A non-cooperative parser must not
// block Stop; its late result is discarded, while a single slot bounds retained
// inputs and prevents parallel use of an engine parser with shared caches.
func (c *runtimeCoordinator) compile(ctx context.Context, input Input, generation uint64) (*RuntimePlan, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	select {
	case c.compileSlots <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-c.compileSlots
			return nil, err
		}
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
