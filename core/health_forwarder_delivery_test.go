//go:build !cgo

package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

// Exercise the real host wire transport; the cgo host has no JNI listener.
func TestSlowCompletedPingIsDeliveredBeforeNextNetworkCheck(t *testing.T) {
	producer, consumer := net.Pipe()
	connMu.Lock()
	previousConnection := conn
	conn = producer
	connMu.Unlock()
	t.Cleanup(func() {
		// Close before taking connMu: a failed test may leave a writer blocked.
		_ = producer.Close()
		_ = consumer.Close()
		connMu.Lock()
		conn = previousConnection
		connMu.Unlock()
	})
	var requests atomic.Int32
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		time.Sleep(4 * time.Second) // Completes after the old three-second warm-up.
		w.WriteHeader(http.StatusNoContent)
	})
	proxy := namedProxy("slow-health-test")
	delivered := make(chan Delay, 1)
	deliveryError := make(chan error, 1)
	_ = consumer.SetReadDeadline(time.Now().Add(8 * time.Second))
	go func() {
		decoder := json.NewDecoder(consumer)
		for {
			var result struct {
				Method Method `json:"method"`
				Data   struct {
					Type MessageType `json:"type"`
					Data Delay       `json:"data"`
				} `json:"data"`
			}
			if err := decoder.Decode(&result); err != nil {
				deliveryError <- err
				return
			}
			if result.Method == messageMethod && result.Data.Type == DelayMessage && result.Data.Data.Name == proxy.Name() && result.Data.Data.Url == server.URL {
				delivered <- result.Data.Data
				return
			}
		}
	}()
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	runLock.Lock()
	previousConfig, previousInterval := currentConfig, minHealthCheckInterval
	previousUI := uiActive.Swap(true)
	currentConfig, minHealthCheckInterval = &config.Config{}, 300*time.Second
	tunnel.UpdateProxies(map[string]constant.Proxy{proxy.Name(): proxy}, nil)
	startHealthCheckForwarder()
	runLock.Unlock()
	t.Cleanup(func() {
		runLock.Lock()
		defer runLock.Unlock()
		stopHealthCheckForwarder()
		currentConfig, minHealthCheckInterval = previousConfig, previousInterval
		uiActive.Store(previousUI)
		tunnel.UpdateProxies(previousProxies, previousProviders)
		resetHealthCheckForwarderState()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	if _, err := proxy.URLTest(ctx, server.URL, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case delay := <-delivered:
		if delay.Value <= 0 {
			t.Fatal("successful ping was delivered as a failure", delay)
		}
	case err := <-deliveryError:
		t.Fatal("ping delivery failed", err)
	case <-time.After(2 * time.Second):
		t.Fatal("completed ping was not delivered before the next network check")
	}
	if requests.Load() != 1 {
		t.Fatal("history polling triggered extra network probes", requests.Load())
	}
}
