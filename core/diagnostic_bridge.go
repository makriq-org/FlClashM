package main

import (
	"bytes"
	"context"
	prepare "core/backend/compile"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	DnsMessage          MessageType = "dns"
	RouteChangedMessage MessageType = "routeChanged"
	maxDiagnosticBytes              = 1 << 20
)

// Route tracking is a projection of the coordinator-owned engine. It never
// applies settings or selections. Follow the existing engine lock order.
var selectMu = &runLock
var methodCallSeq atomic.Uint64

type pickableGroup interface {
	outboundgroup.ProxyGroup
	outboundgroup.SelectAble
}

func allProxies() map[string]constant.Proxy             { return proxiesWithProviders() }
func lookupProxy(name string) constant.Proxy            { return allProxies()[name] }
func providersSnapshot() map[string]cp.ProxyProvider    { return tunnel.Providers() }
func ruleProvidersSnapshot() map[string]cp.RuleProvider { return tunnel.RuleProviders() }
func adapterAs[T any](proxy constant.Proxy) (value T, ok bool) {
	p, ok := proxy.(*adapter.Proxy)
	if !ok {
		return value, false
	}
	value, ok = p.ProxyAdapter.(T)
	return value, ok
}
func diagnosticRunning() bool {
	runLock.Lock()
	defer runLock.Unlock()
	return isRunning || tunUp.Load()
}
func hostWantsEvents() bool { return uiActive.Load() }
func findTracker(matches func(*statistic.TrackerInfo) bool) statistic.Tracker {
	var found statistic.Tracker
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if matches(tracker.Info()) {
			found = tracker
			return false
		}
		return true
	})
	return found
}

var dnsDelivery struct {
	once  sync.Once
	queue chan DnsQuery
}

// DNS is an optional observation. Slow UI delivery must never block a lookup.
func publishDNSQuery(query DnsQuery) {
	if !hostWantsEvents() {
		return
	}
	if len(query.Answers) > 64 {
		query.Answers = query.Answers[:64]
	}
	for i, answer := range query.Answers {
		if len(answer) > 1024 {
			query.Answers[i] = answer[:1024]
		}
	}
	if len(query.Error) > 512 {
		query.Error = query.Error[:512]
	}
	dnsDelivery.once.Do(func() {
		dnsDelivery.queue = make(chan DnsQuery, 64)
		go func() {
			for q := range dnsDelivery.queue {
				if hostWantsEvents() {
					sendMessage(Message{Type: DnsMessage, Data: q})
				}
			}
		}()
	})
	select {
	case dnsDelivery.queue <- query:
	default:
	}
}

func decodeDiagnosticParams(data any, result any) error {
	raw, err := json.Marshal(data)
	if text, ok := data.(string); ok {
		raw = []byte(text)
	}
	if err != nil || len(raw) > maxDiagnosticBytes {
		return errors.New("invalid diagnostic parameters")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if !json.Valid(raw) {
		return errors.New("invalid diagnostic JSON")
	}
	return decoder.Decode(result)
}

// Diagnostic calls are read-only and deliberately bypass the runtime effect
// queue. Runtime writes remain in the authenticated Go application API.
func diagnosticAction(action *Action) (any, error, bool) {
	switch action.Method {
	case "probe":
		var params ProbeParams
		if err := decodeDiagnosticParams(action.Data, &params); err != nil {
			return nil, err, true
		}
		params.MaxBody = min(max(params.MaxBody, 0), 8<<20)
		return handleProbe(&params), nil, true
	case "outboundIp":
		var params OutboundIpParams
		if err := decodeDiagnosticParams(action.Data, &params); err != nil {
			return nil, err, true
		}
		if len(params.Urls) > 16 {
			return nil, errors.New("too many IP sources"), true
		}
		return handleOutboundIp(&params), nil, true
	case "serviceCheck":
		var params ServiceCheckParams
		if err := decodeDiagnosticParams(action.Data, &params); err != nil {
			return nil, err, true
		}
		return handleServiceCheck(&params), nil, true
	case "watchRoute":
		var watch bool
		if err := decodeDiagnosticParams(action.Data, &watch); err != nil {
			return nil, err, true
		}
		seq := action.callSeq
		if seq == 0 {
			seq = methodCallSeq.Add(1)
		}
		return handleWatchRoute(watch, seq), nil, true
	case "setHostActive":
		var active bool
		if err := decodeDiagnosticParams(action.Data, &active); err != nil {
			return nil, err, true
		}
		handleSetUiActive(active)
		if !active {
			stopRouteWatch()
		}
		return true, nil, true
	case "encodeShareLinks":
		var values []map[string]any
		if err := decodeDiagnosticParams(action.Data, &values); err != nil {
			return nil, err, true
		}
		return handleEncodeShareLinks(values), nil, true
	case "decodeShareLinks":
		var values []string
		if err := decodeDiagnosticParams(action.Data, &values); err != nil {
			return nil, err, true
		}
		return handleDecodeShareLinks(values), nil, true
	case "validateFilters":
		var values []string
		if err := decodeDiagnosticParams(action.Data, &values); err != nil {
			return nil, err, true
		}
		return handleValidateFilters(values), nil, true
	case "validateProxies":
		var values []map[string]any
		if err := decodeDiagnosticParams(action.Data, &values); err != nil {
			return nil, err, true
		}
		results := make([]string, len(values))
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		for i, mapping := range values {
			if backendManaged.Load() {
				// Parsing a proxy can create auxiliary listeners. Production
				// validation must stay in the isolated Android validator process.
				err := validateThroughHost(ctx, constant.Path.HomeDir(), prepare.Object{
					"proxies": []any{mapping}, "rules": []string{"MATCH,DIRECT"},
				})
				if err != nil {
					results[i] = err.Error()
				}
				continue
			}
			p, err := adapter.ParseProxy(mapping)
			if err != nil {
				results[i] = err.Error()
			} else {
				_ = p.Close()
			}
		}
		return results, nil, true
	case "getConnectionCount":
		count := 0
		statistic.DefaultManager.Range(func(statistic.Tracker) bool { count++; return true })
		return count, nil, true
	case "getMemoryStats":
		return diagnosticMemory(), nil, true
	case "getProxiesData":
		runLock.Lock()
		defer runLock.Unlock()
		proxies := proxiesWithDescriptions()
		names := []string{}
		seen := map[string]bool{}
		if groups, ok := currentRuntimeRawConfig["proxy-groups"].([]any); ok {
			for _, value := range groups {
				if group, ok := value.(map[string]any); ok {
					if name, ok := group["name"].(string); ok {
						names = append(names, name)
						seen[name] = true
					}
				}
			}
		}
		remaining := []string{}
		for name, p := range allProxies() {
			if _, ok := p.Adapter().(outboundgroup.ProxyGroup); ok && !seen[name] {
				remaining = append(remaining, name)
			}
		}
		sort.Strings(remaining)
		names = append(names, remaining...)
		return ProxiesData{Proxies: proxies, All: names}, nil, true
	}
	return nil, nil, false
}

func diagnosticMemory() MemoryStats {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	value := MemoryStats{HeapInuse: stats.HeapInuse, HeapIdle: stats.HeapIdle, StackInuse: stats.StackInuse, RuntimeOther: stats.Sys - stats.HeapSys - stats.StackSys}
	if raw, err := os.ReadFile("/proc/self/statm"); err == nil {
		fields := strings.Fields(string(raw))
		if len(fields) > 1 {
			pages, _ := strconv.ParseUint(fields[1], 10, 64)
			value.Rss = pages * uint64(os.Getpagesize())
		}
	}
	return value
}

func handleDiagnosticAction(action *Action, result ActionResult) bool {
	value, err, handled := diagnosticAction(action)
	if !handled {
		return false
	}
	if err != nil {
		result.error(fmt.Sprint(err))
	} else {
		result.success(value)
	}
	return true
}
