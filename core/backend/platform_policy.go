package backend

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"reflect"
	"time"
)

// PlatformEvent describes observations only. Android reports OS facts; the
// coordinator decides whether to reset connections, probe or restart a node.
type PlatformEvent struct {
	Sequence  uint64   `json:"seq"`
	Kind      string   `json:"kind"`
	DNS       []string `json:"dns,omitempty"`
	Scope     string   `json:"scope,omitempty"`
	Available bool     `json:"available"`
	Validated bool     `json:"validated"`
	ScreenOn  bool     `json:"screenOn"`
	Dozing    bool     `json:"dozing"`
}
type PlatformEffects interface {
	SystemDNS(context.Context, []string) error
	ResetNetwork(context.Context) error
	ScreenActive(context.Context, bool) error
	Awake(context.Context, bool) error
	ProbeHealth(context.Context) (bool, error)
}
type VPNPermissionReader interface {
	VPNPermission(context.Context) (bool, error)
}
type platformPolicy struct {
	wake                 chan struct{}
	cancel               context.CancelFunc
	pending              map[string]PlatformEvent
	network              PlatformEvent
	screen               PlatformEvent
	lastReset, lastProbe time.Time
	nextProbe, releaseAt time.Time
	missed               bool
	// Per-kind retry state for persistently failing effects ("tick" for the
	// timer); a newer observation of a kind is attempted immediately.
	failures map[string]int
	retryAt  map[string]time.Time
}

const platformRetryLimit = 5 * time.Minute

// platformRetryDelay doubles from one second up to platformRetryLimit.
func platformRetryDelay(failures int) time.Duration {
	delay := time.Second
	for i := 1; i < failures && delay < platformRetryLimit; i++ {
		delay *= 2
	}
	return min(delay, platformRetryLimit)
}

func (b *Backend) NotifyPlatform(event PlatformEvent) error {
	if event.Kind != "network" && event.Kind != "screen" && event.Kind != "service" && event.Kind != "revoked" {
		return errors.New("unsupported platform event")
	}
	if event.Sequence == 0 || len(event.DNS) > 16 || len(event.Scope) > 128 {
		return errors.New("invalid platform event")
	}
	event.DNS = append([]string(nil), event.DNS...)
	c := b.coordinator
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return ErrClosed
	}
	if c.policy == nil {
		c.mu.Unlock()
		return errors.New("platform effects are unavailable")
	}
	if prior, ok := c.policy.pending[event.Kind]; !ok || prior.Sequence < event.Sequence {
		c.policy.pending[event.Kind] = event
		delete(c.policy.failures, event.Kind)
		delete(c.policy.retryAt, event.Kind)
	}
	select {
	case c.policy.wake <- struct{}{}:
	default:
	}
	generation, wanted := c.epoch, c.document.Desired.Running
	c.mu.Unlock()
	if event.Kind == "revoked" && wanted {
		// The policy worker may itself be awaiting service recovery. Persist
		// Stop now so that recovery cannot delay or undo this OS handover.
		_, err := b.SubmitAtGeneration(Request{APIVersion: APIVersion, OperationID: "system-" + rand.Text(), Method: "stop"}, generation)
		if err != nil && !errors.Is(err, ErrSuperseded) {
			return err
		}
		// Keep the event queued: the worker retries failed acceptance and fences
		// a concurrent command if the captured generation was superseded.
	}
	return nil
}
func (c *runtimeCoordinator) openPlatformPolicy() {
	if _, ok := c.engine.(PlatformEffects); !ok {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.policy = &platformPolicy{wake: make(chan struct{}, 1), cancel: cancel, pending: map[string]PlatformEvent{}, screen: PlatformEvent{ScreenOn: true}, failures: map[string]int{}, retryAt: map[string]time.Time{}}
	if c.nodeOptions != nil && c.nodeOptions.ManualTicks {
		return
	}
	go c.platformLoop(ctx)
}

func (c *runtimeCoordinator) platformStarted(ctx context.Context) error {
	effects, ok := c.engine.(PlatformEffects)
	if !ok {
		return nil
	}
	c.mu.Lock()
	p := c.policy
	screen := p.screen
	awake := screen.ScreenOn && !screen.Dozing
	if !screen.Dozing && !p.releaseAt.IsZero() && c.now().Before(p.releaseAt) {
		awake = true
	}
	p.nextProbe = c.now().Add(15 * time.Minute)
	c.mu.Unlock()
	if err := effects.ScreenActive(ctx, screen.ScreenOn && !screen.Dozing); err != nil {
		return err
	}
	return effects.Awake(ctx, awake)
}
func (c *runtimeCoordinator) platformLoop(ctx context.Context) {
	b := &Backend{c}
	for {
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return
		}
		p := c.policy
		// Backoff uses the wall clock of the timers below, not the policy clock.
		now := time.Now()
		retry := time.Time{} // earliest end of a backoff that deferred work
		ready := func(kind string) bool {
			at := p.retryAt[kind]
			if at.IsZero() || !now.Before(at) {
				return true
			}
			if retry.IsZero() || at.Before(retry) {
				retry = at
			}
			return false
		}
		var event *PlatformEvent
		if value, ok := p.pending["revoked"]; ok && ready("revoked") {
			// Revocation is a stop intent and must preempt preparation/recovery,
			// rather than wait for that operation to establish another tunnel.
			copy := value
			event = &copy
		} else if c.active == nil {
			for _, kind := range []string{"service", "screen", "network"} {
				if value, ok := p.pending[kind]; ok && ready(kind) {
					copy := value
					event = &copy
					break
				}
			}
		}
		due := time.Time{}
		if c.document.Desired.Running && c.observed.State == "running" && c.active == nil {
			if p.nextProbe.IsZero() {
				p.nextProbe = c.now().Add(15 * time.Minute)
			}
			due = p.nextProbe
			if !p.releaseAt.IsZero() && (due.IsZero() || p.releaseAt.Before(due)) {
				due = p.releaseAt
			}
		}
		tickDeferred := !due.IsZero() && !ready("tick")
		c.mu.Unlock()
		method := "platform.tick"
		var input json.RawMessage
		if event != nil {
			method = "platform.event"
			input, _ = json.Marshal(event)
		}
		if event != nil || (!due.IsZero() && !tickDeferred && !c.now().Before(due)) {
			kind := "tick"
			if event != nil {
				kind = event.Kind
			}
			id := "system-" + rand.Text()
			var err error
			if event != nil && (event.Kind == "service" || event.Kind == "revoked") {
				err = c.platformLost(ctx, b, id, event.Kind == "revoked")
			} else {
				err = b.runSystemCommand(ctx, id, EngineCommand{Method: method, Params: input})
			}
			if ctx.Err() != nil {
				return
			}
			c.mu.Lock()
			if err == nil {
				delete(p.failures, kind)
				delete(p.retryAt, kind)
				if event != nil {
					if latest := p.pending[event.Kind]; latest.Sequence == event.Sequence {
						delete(p.pending, event.Kind)
					}
				}
			} else if event == nil || p.pending[event.Kind].Sequence == event.Sequence {
				// A persistently failing effect must not spin; a newer
				// observation of the same kind already reset its backoff.
				p.failures[kind]++
				p.retryAt[kind] = time.Now().Add(platformRetryDelay(p.failures[kind]))
			}
			c.mu.Unlock()
			continue
		}
		var timer *time.Timer
		var tick <-chan time.Time
		wait := time.Duration(-1)
		consider := func(at time.Time) {
			if at.IsZero() {
				return
			}
			if d := max(time.Millisecond, time.Until(at)); wait < 0 || d < wait {
				wait = d
			}
		}
		if !tickDeferred {
			consider(due)
		}
		consider(retry)
		if wait >= 0 {
			timer = time.NewTimer(wait)
			tick = timer.C
		}
		select {
		case <-ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			return
		case <-p.wake:
		case <-tick:
		}
		if timer != nil {
			timer.Stop()
		}
	}
}

func (c *runtimeCoordinator) platformLost(ctx context.Context, b *Backend, id string, revoked bool) error {
	c.mu.Lock()
	generation, wanted := c.epoch, c.document.Desired.Running
	c.mu.Unlock()
	if !wanted {
		return nil
	}
	method := "recover"
	if revoked {
		// Android revoked this session (for example, another VPN took over).
		// Permission and a possibly stale observation cannot authorize recovery.
		method = "stop"
	} else {
		observed, err := c.platform.Observe(ctx)
		if err != nil {
			return err
		}
		if observed.State == "running" {
			return nil
		}
	}
	if _, err := b.SubmitAtGeneration(Request{APIVersion: APIVersion, OperationID: id, Method: method}, generation); err != nil {
		return err
	}
	_, err := b.Await(ctx, id)
	return err
}

// Caller holds commands. Bookkeeping is protected by mu for the timer worker;
// every mechanism call remains serialized with plan installation and Stop.
func (c *runtimeCoordinator) platformCommand(ctx context.Context, command EngineCommand) error {
	effects, ok := c.engine.(PlatformEffects)
	if !ok {
		return errors.New("platform effects are unavailable")
	}
	var event PlatformEvent
	if command.Method == "platform.event" {
		if err := json.Unmarshal(command.Params, &event); err != nil {
			return err
		}
	}
	c.mu.Lock()
	p := c.policy
	if p == nil {
		c.mu.Unlock()
		return errors.New("platform policy is unavailable")
	}
	running := c.document.Desired.Running && c.observed.State == "running"
	now := c.now()
	releaseAt, nextProbe, missed := p.releaseAt, p.nextProbe, p.missed
	network := p.network
	screen := p.screen
	if event.Kind == "network" && event.Sequence <= network.Sequence {
		c.mu.Unlock()
		return nil
	}
	if event.Kind == "screen" && event.Sequence <= screen.Sequence {
		c.mu.Unlock()
		return nil
	}
	needReset := event.Kind == "network" && event.Available && (network.Sequence == 0 || event.Scope != network.Scope || !network.Available || (!network.Validated && event.Validated) || !reflect.DeepEqual(network.DNS, event.DNS))
	reset := running && needReset && (p.lastReset.IsZero() || now.Sub(p.lastReset) >= 5*time.Second)
	probe := false
	release := false
	awake := false
	if event.Kind == "screen" {
		if event.ScreenOn && !event.Dozing {
			awake = running
			releaseAt = time.Time{}
			probe = running && missed
		}
		if event.Dozing {
			release = running
			releaseAt = time.Time{}
		} else if !event.ScreenOn {
			awake = running
			releaseAt = now.Add(2 * time.Minute)
		}
	}
	if running && needReset && screen.ScreenOn && !screen.Dozing {
		probe = true
	}
	if command.Method == "platform.tick" && running {
		if !releaseAt.IsZero() && !now.Before(releaseAt) {
			release = true
			releaseAt = time.Time{}
		}
		if !nextProbe.IsZero() && !now.Before(nextProbe) {
			nextProbe = now.Add(15 * time.Minute)
			if screen.ScreenOn && !screen.Dozing {
				probe = true
			} else {
				missed = true
			}
		}
	}
	if probe && !p.lastProbe.IsZero() && now.Sub(p.lastProbe) < 45*time.Second {
		probe = false
	}
	c.mu.Unlock()
	if event.Kind == "screen" {
		if err := effects.ScreenActive(ctx, event.ScreenOn && !event.Dozing); err != nil {
			return err
		}
	}
	if event.Kind == "network" && !reflect.DeepEqual(network.DNS, event.DNS) && len(event.DNS) > 0 {
		if err := effects.SystemDNS(ctx, event.DNS); err != nil {
			return err
		}
	}
	if reset {
		if err := effects.ResetNetwork(ctx); err != nil {
			return err
		}
	}
	if release {
		if err := effects.Awake(ctx, false); err != nil {
			return err
		}
	}
	if awake {
		if err := effects.Awake(ctx, true); err != nil {
			return err
		}
	}
	if running && event.Kind == "network" && network.Sequence != 0 && (event.Scope != network.Scope || !reflect.DeepEqual(event.DNS, network.DNS)) && c.nodeOptions != nil {
		for _, id := range c.nodeOrder {
			n := c.nodes[id]
			if !n.awake {
				continue
			}
			if n.plan.Metadata["depends-on-system-dns"] != "true" && n.auto == nil {
				continue
			}
			if err := c.nodeOptions.Adapter.Stop(ctx, id); err != nil {
				return err
			}
			err := c.nodeOptions.Adapter.Prepare(ctx, n.plan.Clone())
			if err == nil && n.auto != nil {
				err = c.selectForeground(ctx, n)
			}
			if err == nil {
				err = c.launchNode(ctx, n)
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				n.awake = true
				n.observed = "degraded"
				n.retryUntil = now.Add(5 * time.Minute)
			}
		}
		c.publishNodes()
	}
	if probe {
		probeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		healthy, err := effects.ProbeHealth(probeCtx)
		cancel()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil || !healthy {
			if err = effects.ResetNetwork(ctx); err != nil {
				return err
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	p.releaseAt, p.nextProbe, p.missed = releaseAt, nextProbe, missed
	if event.Kind == "network" {
		p.network = event
	}
	if event.Kind == "screen" {
		p.screen = event
	}
	if reset {
		p.lastReset = now
	}
	if probe {
		p.lastProbe = now
		p.missed = false
		p.nextProbe = now.Add(15 * time.Minute)
	}
	return nil
}
