package backend

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
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
	return ctx.Err()
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

type coordinatedTransports struct{ c *runtimeCoordinator }

func (a coordinatedTransports) Prepare(ctx context.Context, p *RuntimePlan) error {
	return a.c.prepareNodes(ctx, p)
}
func (a coordinatedTransports) Start(ctx context.Context, _ *RuntimePlan) error {
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
