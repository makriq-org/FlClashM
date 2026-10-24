package backend

import (
	"context"
	"errors"
	"math"
	"sync"
	"time"
)

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
				passed, err := c.nodeOptions.Adapter.Probe(probeCtx, NodeProbe{Host: node.Host, Port: node.Port, URL: address, Resolver: check.Resolver, RequireSuccess: check.RequireSuccess})
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
