package backend

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"
)

type StrategyCache struct {
	Version           int       `json:"version,omitempty"`
	Fingerprint       string    `json:"fingerprint"`
	Strategy          string    `json:"strategy"`
	CheckedAt         time.Time `json:"checkedAt"`
	Failures          int       `json:"failures"`
	SelectionRevision int       `json:"selectionRevision"`
	Verified          bool      `json:"verified"`
	NextIndex         int       `json:"nextIndex"`
}
type StrategyCacheStore interface {
	Read(context.Context, string, string) (StrategyCache, error)
	Write(context.Context, string, string, StrategyCache) error
}
type NodeOptions struct {
	Adapter    NodeAdapter
	Inspection RuntimeInspection
	Cache      StrategyCacheStore
	ABI        string
	Now        func() time.Time
	Wait       func(context.Context, time.Duration) error
	// ManualTicks lets a deterministic test host drive reconciliation explicitly.
	ManualTicks bool
}
type NodeSnapshot struct {
	ID           string `json:"nodeId"`
	State        string `json:"state"`
	Awake        bool   `json:"awake"`
	Verified     bool   `json:"strategyVerified,omitempty"`
	Pending      bool   `json:"selectionPending,omitempty"`
	Connectivity string `json:"connectivity,omitempty"`
}
type NodePersisted struct {
	Awake bool `json:"awake"`
}
type nodeRuntime struct {
	nextObservation                 time.Time
	optionalPending                 bool
	optionalDeadline, nextOptional  time.Time
	connectivity                    string
	plan                            NodePlan
	awake                           bool
	observed                        string
	failures                        int
	nextCheck, timeIdle, retryUntil time.Time
	strategy                        string
	auto                            *autoOptions
	cache                           StrategyCache
	scope                           string
	pending                         bool
	nextStrategy                    int
	recheck                         bool
}
type autoOptions struct {
	Mode       string   `json:"mode"`
	Args       string   `json:"args"`
	Strategies []string `json:"strategies"`
	Test       struct {
		URLs        []string `json:"urls"`
		SNI         string   `json:"sni"`
		Resolver    string   `json:"resolver"`
		Timeout     int64    `json:"timeout"`
		Requests    int      `json:"requests"`
		Concurrency int      `json:"concurrency"`
		Ratio       float64  `json:"min-success-ratio"`
	} `json:"strategyTest"`
	Selection struct {
		Concurrency int   `json:"concurrency"`
		Foreground  int64 `json:"foreground-timeout"`
		Background  bool  `json:"background"`
	} `json:"selection"`
	Cache struct {
		TTL      int64 `json:"ttl"`
		Recheck  int64 `json:"recheck-after"`
		Failures int   `json:"failure-threshold"`
		Retry    int64 `json:"retry-after"`
	} `json:"cache"`
	Fallback string `json:"fallbackArgs"`
}

func (c *runtimeCoordinator) now() time.Time {
	if c.nodeOptions != nil && c.nodeOptions.Now != nil {
		return c.nodeOptions.Now()
	}
	return time.Now()
}
func (c *runtimeCoordinator) wait(ctx context.Context, d time.Duration) error {
	if c.nodeOptions != nil && c.nodeOptions.Wait != nil {
		return c.nodeOptions.Wait(ctx, d)
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (c *runtimeCoordinator) publishNodes(epoch ...uint64) {
	snapshots := make([]NodeSnapshot, 0, len(c.nodeOrder))
	for _, id := range c.nodeOrder {
		n := c.nodes[id]
		snapshots = append(snapshots, NodeSnapshot{ID: id, State: n.observed, Awake: n.awake, Verified: n.cache.Verified, Pending: n.pending, Connectivity: n.connectivity})
	}
	c.mu.Lock()
	if len(epoch) > 0 && c.epoch != epoch[0] {
		c.mu.Unlock()
		return
	}
	if !reflect.DeepEqual(c.nodeSnapshot, snapshots) {
		c.nodeSnapshot = snapshots
		c.publishLocked()
	}
	c.mu.Unlock()
}
func (c *runtimeCoordinator) persistedNodes() map[string]NodePersisted {
	out := map[string]NodePersisted{}
	for id, n := range c.nodes {
		out[id] = NodePersisted{Awake: n.awake}
	}
	return out
}
func (c *runtimeCoordinator) prepareNodes(ctx context.Context, plan *RuntimePlan) error {
	var data struct {
		Nodes    []NodePlan        `json:"nodes"`
		Selected map[string]string `json:"selected-map"`
	}
	if err := json.Unmarshal(plan.Payload(), &data); err != nil {
		return err
	}
	c.nodesDigest = ""
	c.nodes = map[string]*nodeRuntime{}
	c.nodeOrder = nil
	c.mu.Lock()
	persisted := map[string]NodePersisted{}
	if c.document.Applied != nil {
		var prior struct {
			Nodes []NodePlan `json:"nodes"`
		}
		_ = json.Unmarshal(c.document.Applied.Plan.Payload, &prior)
		for _, candidate := range data.Nodes {
			for _, old := range prior.Nodes {
				if candidate.ID == old.ID && reflect.DeepEqual(candidate, old) {
					persisted[candidate.ID] = c.document.Applied.Nodes[candidate.ID]
					break
				}
			}
		}
	}
	c.mu.Unlock()
	for _, node := range data.Nodes {
		if _, duplicate := c.nodes[node.ID]; duplicate {
			return errors.New("duplicate external node identity")
		}
		n := &nodeRuntime{plan: node.Clone(), observed: "stopped", nextCheck: c.now()}
		n.awake = node.Activation == nil || node.Activation.Mode != "auto" || persisted[node.ID].Awake
		if !n.awake {
			for _, selected := range data.Selected {
				if selected == node.Name {
					n.awake = true
				}
			}
		}
		if node.Type == "byedpi" {
			var config autoOptions
			raw := node.Files["built-in-proxies/byedpi/"+node.ID+"/config.json"]
			if json.Unmarshal([]byte(raw), &config) != nil {
				return errors.New("invalid compiled ByeDPI options")
			}
			if config.Mode == "auto" {
				if len(config.Strategies) == 0 || config.Selection.Concurrency < 1 || config.Selection.Concurrency > 16 || config.Test.Timeout < 1 || config.Test.Timeout > 60 {
					return errors.New("invalid auto-selection limits")
				}
				n.auto = &config
			} else {
				n.strategy = config.Args
			}
		}
		if err := c.nodeOptions.Adapter.Prepare(ctx, node.Clone()); err != nil {
			return err
		}
		c.nodes[node.ID] = n
		c.nodeOrder = append(c.nodeOrder, node.ID)
	}
	c.publishNodes()
	if err := ctx.Err(); err != nil {
		return err
	}
	c.nodesDigest = plan.Digest()
	return nil
}
func (c *runtimeCoordinator) startNodes(ctx context.Context) error {
	for _, id := range c.nodeOrder {
		n := c.nodes[id]
		if !n.awake {
			n.observed = "sleeping"
			continue
		}
		if n.auto != nil {
			if err := c.selectForeground(ctx, n); err != nil {
				return err
			}
		}
		if err := c.launchNode(ctx, n); err != nil {
			return err
		}
	}
	c.publishNodes()
	return nil
}
func (c *runtimeCoordinator) launchNode(ctx context.Context, n *nodeRuntime) error {
	launch := NodeLaunch{Node: n.plan.Clone(), Strategy: n.strategy}
	if n.auto != nil {
		launch.SNI = n.auto.Test.SNI
	}
	if err := c.nodeOptions.Adapter.Start(ctx, launch); err != nil {
		return err
	}
	startup := time.Duration(n.plan.Check.StartupTimeout) * time.Second
	if startup <= 0 {
		startup = 30 * time.Second
	}
	readyCtx, cancel := context.WithTimeout(ctx, startup)
	defer cancel()
	if err := c.waitListening(readyCtx, n.plan); err != nil {
		return err
	}
	if n.plan.Check.Required {
		for {
			passed, err := c.checkNode(readyCtx, n.plan, n.plan.Check)
			if err != nil {
				return err
			}
			if passed {
				break
			}
			interval := time.Duration(n.plan.Check.RetryInterval) * time.Second
			if interval <= 0 {
				interval = time.Second
			}
			if err = c.wait(readyCtx, interval); err != nil {
				return err
			}
		}
	}
	n.awake = true
	n.nextObservation = c.now().Add(30 * time.Second)
	n.optionalPending = !n.plan.Check.Required && len(n.plan.Check.URLs) > 0
	n.nextOptional = c.now()
	n.optionalDeadline = c.now().Add(startup)
	n.observed = "running"
	return ctx.Err()
}
func (c *runtimeCoordinator) waitListening(ctx context.Context, node NodePlan) error {
	for {
		observation, err := c.nodeOptions.Adapter.Observe(ctx, node.ID)
		if err != nil {
			return err
		}
		if observation.State != "running" {
			return errors.New("external process exited during startup")
		}
		ready, err := c.nodeOptions.Adapter.Listening(ctx, node.Clone())
		if err != nil {
			return err
		}
		if ready {
			return nil
		}
		if err = c.wait(ctx, 25*time.Millisecond); err != nil {
			return err
		}
	}
}
func (c *runtimeCoordinator) checkNode(ctx context.Context, node NodePlan, check NodeCheck) (bool, error) {
	requests := check.Requests
	if requests < 1 {
		requests = 1
	}
	total := len(check.URLs) * requests
	if total == 0 {
		return false, nil
	}
	required := 1
	if check.MinSuccessRatio != nil {
		required = int(math.Ceil(*check.MinSuccessRatio * float64(total)))
	}
	concurrency := check.Concurrency
	if concurrency < 1 {
		concurrency = 1
	}
	concurrency = min(concurrency, total)
	checkCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan string, total)
	for _, address := range check.URLs {
		for range requests {
			jobs <- address
		}
	}
	close(jobs)
	results := make(chan bool, total)
	var workers sync.WaitGroup
	for range concurrency {
		workers.Go(func() {
			for address := range jobs {
				if checkCtx.Err() != nil {
					return
				}
				timeout := time.Duration(check.Timeout) * time.Second
				if timeout <= 0 {
					timeout = 5 * time.Second
				}
				probeCtx, done := context.WithTimeout(checkCtx, timeout)
				passed, err := c.nodeOptions.Adapter.Probe(probeCtx, NodeProbe{Host: node.Host, Port: node.Port, URL: address, Resolver: check.Resolver})
				done()
				results <- passed && err == nil
			}
		})
	}
	go func() { workers.Wait(); close(results) }()
	successes, completed := 0, 0
	for passed := range results {
		completed++
		if passed {
			successes++
		}
		if successes >= required || successes+total-completed < required {
			cancel()
		}
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	return successes >= required, nil
}
func autoFingerprint(abi string, options autoOptions) string {
	ratio := strconv.FormatFloat(options.Test.Ratio, 'f', -1, 64)
	if !strings.ContainsAny(ratio, ".eE") {
		ratio += ".0"
	}
	source := struct {
		Release     string          `json:"release"`
		Strategies  []string        `json:"strategies"`
		URLs        []string        `json:"urls"`
		SNI         string          `json:"sni"`
		Resolver    string          `json:"resolver"`
		Timeout     int64           `json:"timeout"`
		Requests    int             `json:"requests"`
		Concurrency int             `json:"concurrency"`
		Ratio       json.RawMessage `json:"minSuccessRatio"`
		Fallback    string          `json:"fallbackStrategy"`
	}{abi + "git-ba532298de7b28cfe854aea83d061369d13ca290", options.Strategies, options.Test.URLs, options.Test.SNI, options.Test.Resolver, options.Test.Timeout, options.Test.Requests, options.Test.Concurrency, json.RawMessage(ratio), options.Fallback}
	var data bytes.Buffer
	encoder := json.NewEncoder(&data)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(source)
	sum := sha256.Sum256(bytes.TrimSuffix(data.Bytes(), []byte{'\n'}))
	return hex.EncodeToString(sum[:])
}
func (c *runtimeCoordinator) selectForeground(ctx context.Context, n *nodeRuntime) error {
	scope, err := c.nodeOptions.Inspection.NetworkScope(ctx)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil || scope == "" {
		scope = "default"
	}
	n.scope = scope
	options := n.auto
	fingerprint := autoFingerprint(c.nodeOptions.ABI, *options)
	cached, _ := c.nodeOptions.Cache.Read(ctx, n.plan.ID, scope)
	valid := cached.Fingerprint == fingerprint && cached.SelectionRevision == 2
	n.cache = cached
	n.pending = false
	n.recheck = false
	n.nextStrategy = 0
	if valid && cached.Verified && c.now().Sub(cached.CheckedAt) <= time.Duration(options.Cache.TTL)*time.Second {
		n.strategy = cached.Strategy
		if c.now().Sub(cached.CheckedAt) >= time.Duration(options.Cache.Recheck)*time.Second {
			n.recheck = true
			n.pending = true
		}
		return nil
	}
	start := 0
	if valid && !cached.Verified {
		if c.now().Sub(cached.CheckedAt) < time.Duration(options.Cache.Retry)*time.Second {
			n.strategy = cached.Strategy
			return nil
		}
		start = cached.NextIndex
		if start < 0 || start >= len(options.Strategies) {
			start = 0
		}
	}
	selected, next, err := c.probeStrategies(ctx, n, start, time.Duration(options.Selection.Foreground)*time.Second)
	if err != nil {
		return err
	}
	n.strategy = selected
	verified := selected != ""
	if !verified {
		n.strategy = options.Fallback
		n.pending = options.Selection.Background && next < len(options.Strategies)
		n.nextStrategy = next
	}
	if next >= len(options.Strategies) {
		next = 0
	}
	n.cache = StrategyCache{Version: 1, Fingerprint: fingerprint, Strategy: n.strategy, CheckedAt: c.now().UTC(), SelectionRevision: 2, Verified: verified, NextIndex: next}
	return c.nodeOptions.Cache.Write(ctx, n.plan.ID, scope, n.cache)
}
func (c *runtimeCoordinator) probeStrategies(ctx context.Context, n *nodeRuntime, start int, budget time.Duration) (string, int, error) {
	options := n.auto
	if budget <= 0 {
		return "", start, nil
	}
	deadline := time.Now().Add(budget)
	next := start
	for next < len(options.Strategies) {
		remaining := time.Until(deadline)
		if remaining < time.Second {
			break
		}
		end := min(next+options.Selection.Concurrency, len(options.Strategies))
		batchCtx, cancel := context.WithTimeout(ctx, min(remaining, time.Duration(options.Test.Timeout)*time.Second))
		selected, err := c.probeBatch(batchCtx, n, options.Strategies[next:end])
		cancel()
		next = end
		if ctx.Err() != nil {
			return "", next, ctx.Err()
		}
		if selected != "" {
			return selected, next, nil
		}
		if err != nil && !errors.Is(err, context.DeadlineExceeded) {
			return "", next, err
		}
	}
	return "", next, nil
}
func (c *runtimeCoordinator) probeBatch(ctx context.Context, n *nodeRuntime, strategies []string) (string, error) {
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		strategy string
		err      error
	}
	results := make(chan result, len(strategies))
	ports := map[int]bool{}
	launches := []NodeLaunch{}
	for _, strategy := range strategies {
		port := 0
		for range len(strategies)*16 + 16 {
			candidate, err := c.nodeOptions.Adapter.AllocatePort(child)
			if err != nil {
				return "", err
			}
			if !ports[candidate] {
				ports[candidate] = true
				port = candidate
				break
			}
		}
		if port == 0 {
			return "", errors.New("cannot allocate distinct probe ports")
		}
		sum := md5.Sum([]byte(strategy))
		node := n.plan.Clone()
		node.ID += "-probe-" + hex.EncodeToString(sum[:])
		node.Port = port
		launches = append(launches, NodeLaunch{Node: node, Strategy: strategy, SNI: n.auto.Test.SNI, Probe: true})
	}
	for _, launch := range launches {
		go func(launch NodeLaunch) {
			outcome := func() result {
				err := c.nodeOptions.Adapter.Start(child, launch)
				if err == nil {
					err = c.waitListening(child, launch.Node)
				}
				passed := false
				if err == nil {
					ratio := n.auto.Test.Ratio
					passed, err = c.checkNode(child, launch.Node, NodeCheck{URLs: n.auto.Test.URLs, Timeout: n.auto.Test.Timeout, Requests: n.auto.Test.Requests, Concurrency: n.auto.Test.Concurrency, MinSuccessRatio: &ratio, Resolver: n.auto.Test.Resolver})
				}
				cleanup, done := context.WithTimeout(context.Background(), 15*time.Second)
				defer done()
				if err := c.nodeOptions.Adapter.Stop(cleanup, launch.Node.ID); err != nil {
					return result{err: err}
				}
				if passed {
					return result{strategy: launch.Strategy}
				}
				return result{}
			}()
			results <- outcome
		}(launch)
	}

	selected := ""
	var resultErr error
	for range launches {
		result := <-results
		if selected == "" && result.strategy != "" {
			selected = result.strategy
			cancel()
		}
		if result.err != nil {
			resultErr = errors.Join(resultErr, result.err)
		}
	}
	if ctx.Err() != nil && selected == "" {
		return "", ctx.Err()
	}
	if resultErr != nil {
		return "", resultErr
	}
	if selected != "" {
		return selected, nil
	}
	return "", nil
}

// This aggregate is internal to the coordinator. The host implements only the
// per-process NodeAdapter; it cannot install an independent supervising path.
type coordinatedTransports struct{ c *runtimeCoordinator }

func (a coordinatedTransports) Prepare(ctx context.Context, p *RuntimePlan) error {
	return a.c.prepareNodes(ctx, p)
}
func (a coordinatedTransports) Start(ctx context.Context, p *RuntimePlan) error {
	// Node definitions come from the last completed Prepare. Never launch
	// another plan's processes, e.g. those left by a superseded install.
	if p == nil || a.c.nodesDigest != p.Digest() {
		return errors.New("external nodes are not prepared for this plan")
	}
	if err := a.c.startNodes(ctx); err != nil {
		return err
	}
	a.c.nodesExecuting = true
	return nil
}
func (a coordinatedTransports) Stop(ctx context.Context) error {
	err := a.c.nodeOptions.Adapter.StopAll(ctx)
	a.c.nodesExecuting = false
	for _, node := range a.c.nodes {
		node.observed = "stopped"
		if err != nil {
			node.observed = "unknown"
		}
	}
	a.c.publishNodes()
	return err
}
func (a coordinatedTransports) Observe(ctx context.Context) (Observation, error) {
	if !a.c.nodesExecuting {
		return Observation{State: "stopped"}, nil
	}
	for _, node := range a.c.nodes {
		if !node.awake {
			continue
		}
		observation, err := a.c.nodeOptions.Adapter.Observe(ctx, node.plan.ID)
		if err != nil {
			return Observation{}, err
		}
		if observation.State != "running" {
			return observation, nil
		}
	}
	return Observation{State: "running"}, nil
}
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
func (c *runtimeCoordinator) continueSelection(ctx context.Context, node *nodeRuntime, generation uint64) error {
	options := node.auto
	if options == nil {
		node.pending = false
		return nil
	}
	if node.recheck {
		selected, err := c.probeBatch(ctx, node, []string{node.cache.Strategy})
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			return err
		}
		if selected != "" {
			node.cache.CheckedAt = c.now().UTC()
			node.cache.Failures = 0
			node.pending = false
			node.recheck = false
			return c.nodeOptions.Cache.Write(ctx, node.plan.ID, node.scope, node.cache)
		}
		node.cache.Failures++
		if node.cache.Failures < options.Cache.Failures {
			node.pending = false
			node.recheck = false
			return c.nodeOptions.Cache.Write(ctx, node.plan.ID, node.scope, node.cache)
		}
		node.recheck = false
	}
	start := node.nextStrategy
	end := min(start+options.Selection.Concurrency, len(options.Strategies))
	if start >= end {
		node.pending = false
		return nil
	}
	probeCtx, cancel := context.WithTimeout(ctx, time.Duration(options.Test.Timeout)*time.Second)
	selected, err := c.probeBatch(probeCtx, node, options.Strategies[start:end])
	cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil && !errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	node.nextStrategy = end
	if selected == "" && end < len(options.Strategies) {
		node.cache.NextIndex = end
		if !node.cache.Verified {
			node.cache.CheckedAt = c.now().UTC()
			return c.nodeOptions.Cache.Write(ctx, node.plan.ID, node.scope, node.cache)
		}
		return nil
	}
	verified := selected != ""
	if !verified {
		selected = options.Fallback
	}
	previous := node.cache
	previousStrategy := node.strategy
	next := StrategyCache{Version: 1, Fingerprint: previous.Fingerprint, Strategy: selected, CheckedAt: c.now().UTC(), SelectionRevision: 2, Verified: verified}
	if selected != previousStrategy {
		if err := c.nodeOptions.Adapter.Stop(ctx, node.plan.ID); err != nil {
			return err
		}
		node.strategy = selected
		if err := c.launchNode(ctx, node); err != nil {
			node.strategy = previousStrategy
			cleanup, done := context.WithTimeout(context.Background(), c.cleanupTimeout)
			defer done()
			_ = c.nodeOptions.Adapter.Stop(cleanup, node.plan.ID)
			var restoreErr error
			if c.nodeGenerationCurrent(generation) {
				restoreErr = c.launchNode(cleanup, node)
			}
			return errors.Join(err, restoreErr)
		}
	}
	if err := c.nodeOptions.Cache.Write(ctx, node.plan.ID, node.scope, next); err != nil {
		if selected != previousStrategy {
			node.strategy = previousStrategy
			cleanup, done := context.WithTimeout(context.Background(), c.cleanupTimeout)
			defer done()
			stopErr := c.nodeOptions.Adapter.Stop(cleanup, node.plan.ID)
			var restoreErr error
			if c.nodeGenerationCurrent(generation) {
				restoreErr = c.launchNode(cleanup, node)
			}
			return errors.Join(err, stopErr, restoreErr)
		}
		return err
	}
	node.cache = next
	node.pending = false
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
		if observation.State != "running" {
			node.observed = observation.State
			if now.Before(node.retryUntil) {
				return nil
			}
			_ = c.nodeOptions.Adapter.Stop(ctx, node.plan.ID)
			if err = c.launchNode(ctx, node); err != nil {
				node.observed = "degraded"
				node.retryUntil = c.now().Add(5 * time.Minute)
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
