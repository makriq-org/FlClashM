package main

import (
	"context"
	"core/backend"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// Values the UI understands: a positive number is a delay in milliseconds,
// delayTimedOut means the probe ran out of time, and delayFailed means it
// finished without an answer.
const (
	delayTimedOut int32 = -1
	delayFailed   int32 = -2
)

func delayValue(delay uint16, timedOut bool) int32 {
	switch {
	case delay > 0:
		return int32(delay)
	case timedOut:
		return delayTimedOut
	default:
		return delayFailed
	}
}

// waitForDelaySlot reserves one of the shared test slots within timeout. The
// reservation is for queueing only, so the probe that follows keeps its whole
// budget.
func waitForDelaySlot(wait context.Context, timeout time.Duration) bool {
	waiting, cancel := context.WithTimeout(wait, timeout)
	defer cancel()
	return testDelaySem.Acquire(waiting, 1) == nil
}

// testDelay measures one node. A false second value means the test never got a
// slot, which says nothing about the node itself.
func testDelay(
	wait context.Context,
	proxy constant.Proxy,
	url string,
	timeout time.Duration,
	expected utils.IntRanges[uint16],
) (int32, bool) {
	if _, ok := adapterAs[*outboundgroup.LoadBalance](proxy); ok {
		return testBalancerDelay(wait, balancedNodes(proxy), url, timeout, expected)
	}
	if !waitForDelaySlot(wait, timeout) {
		return 0, false
	}
	defer testDelaySem.Release(1)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	delay, err := proxy.URLTest(ctx, url, expected)
	if err != nil {
		delay = 0
	}
	return delayValue(delay, ctx.Err() != nil), true
}

type nodeDelay struct {
	value  int32
	tested bool
}

// A balancer answers with the member its strategy would pick, so a single probe
// through the group reports a dead member it has not ruled out yet as the whole
// group's delay. Its members are probed instead, each in its own slot, and the
// group answers with the first that succeeds.
//
// Probes still running when the group answers carry on: mihomo records a probe
// cut short as a dead node, so only nodes still queueing for a slot give up.
func testBalancerDelay(
	wait context.Context,
	nodes []constant.Proxy,
	url string,
	timeout time.Duration,
	expected utils.IntRanges[uint16],
) (int32, bool) {
	if len(nodes) == 0 {
		// Every member is asleep or the group names none, so nothing was probed
		// and the group has no reading to report either way.
		return 0, false
	}
	wait, answered := context.WithCancel(wait)
	defer answered()
	results := make(chan nodeDelay, len(nodes))
	for _, node := range nodes {
		goDelayTest("balancer delay test", func() {
			var result nodeDelay
			defer func() { results <- result }()
			result.value, result.tested = testDelay(wait, node, url, timeout, expected)
		})
	}
	value, complete := delayFailed, true
	for range nodes {
		result := <-results
		if result.value > 0 {
			return result.value, true
		}
		complete = complete && result.tested
		value = max(value, result.value)
	}
	return value, complete
}

// balancedNodes lists the nodes a balancer reaches, following nested balancers
// and the picks of other groups, each node once however many groups lead to it.
// A sleeping external node has no listener to reach, and probing it would record
// a live node as dead, so it is left out.
func balancedNodes(balancer constant.Proxy) []constant.Proxy {
	asleep := sleepingNodes()
	var nodes []constant.Proxy
	seen := map[constant.Proxy]bool{}
	var walk func(proxy constant.Proxy)
	walk = func(proxy constant.Proxy) {
		if seen[proxy] {
			return
		}
		seen[proxy] = true
		if inner, ok := adapterAs[*outboundgroup.LoadBalance](proxy); ok {
			for _, member := range inner.Proxies() {
				walk(member)
			}
			return
		}
		if pick := proxy.Unwrap(nil, false); pick != nil {
			walk(pick)
			return
		}
		if asleep[proxy.Name()] {
			return
		}
		nodes = append(nodes, proxy)
	}
	walk(balancer)
	return nodes
}

// sleepingNodes reports the external nodes the runtime keeps asleep. They are
// selectable but have no listener until something wakes them, so a probe of one
// would only record a live node as dead.
func sleepingNodes() map[string]bool {
	names := map[string]bool{}
	for _, node := range runtimeNodes() {
		if !node.Awake || node.State == "sleeping" {
			names[node.Name] = true
		}
	}
	return names
}

// runtimeNodes reads the node snapshots of the running backend; tests replace
// it to describe a runtime without one.
var runtimeNodes = func() []backend.NodeSnapshot {
	applicationMu.Lock()
	app := applicationBackend
	applicationMu.Unlock()
	if app == nil {
		return nil
	}
	return app.Snapshot().Runtime.Nodes
}

// A node whose adapter panics must not take the Core down or leave the group
// waiting for an answer that never comes.
func goDelayTest(name string, run func()) {
	go func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				log.Errorln("panic in %s: %v", name, recovered)
			}
		}()
		run()
	}()
}
