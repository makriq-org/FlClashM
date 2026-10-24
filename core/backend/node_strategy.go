package backend

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
)

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
	valid := cached.Fingerprint == fingerprint && cached.SelectionRevision == 3
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
	n.cache = StrategyCache{Version: 1, Fingerprint: fingerprint, Strategy: n.strategy, CheckedAt: c.now().UTC(), SelectionRevision: 3, Verified: verified, NextIndex: next}
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
					passed, err = c.checkNode(child, launch.Node, NodeCheck{URLs: n.auto.Test.URLs, Timeout: n.auto.Test.Timeout, Requests: n.auto.Test.Requests, Concurrency: n.auto.Test.Concurrency, MinSuccessRatio: &ratio, Resolver: n.auto.Test.Resolver, RequireSuccess: true})
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
	next := StrategyCache{Version: 1, Fingerprint: previous.Fingerprint, Strategy: selected, CheckedAt: c.now().UTC(), SelectionRevision: 3, Verified: verified}
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
