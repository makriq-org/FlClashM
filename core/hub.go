package main

import (
	"context"
	"core/state"
	"encoding/json"
	"fmt"
	"net"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	isInit              atomic.Bool
	externalProviders   = map[string]cp.Provider{}
	logSubscriber       observable.Subscription[log.Event]
	healthCheckStopCh   chan struct{}
	healthCheckChMu     sync.Mutex
	healthCheckMu       sync.Mutex
	healthCheckSeen     = map[string]string{}
	requestStopCh       chan struct{}
	requestChMu         sync.Mutex
	requestMu           sync.Mutex
	requestSeen         = map[string]bool{}
	// uiActive reflects whether the Flutter UI is in the foreground. When false
	// (app backgrounded) the request forwarder is paused and the health-check
	// forwarder slows to backgroundHealthCheckInterval, so the core stops pinging
	// every proxy and waking Flutter for a UI nobody is looking at.
	uiActive atomic.Bool
	// tunUp is true while the VpnService TUN is up (set in handleStartTun, cleared in
	// handleStopTun/handleShutdown). A headless tile/boot start brings the TUN up via
	// Core.startTun WITHOUT calling startListener, so isRunning stays false — yet the
	// connections "Journal" (request forwarder) must still run when the UI is
	// foregrounded. Gating the forwarder on (isRunning || tunUp) covers that path too,
	// while it stays uiActive-gated so it never polls during standby.
	tunUp atomic.Bool
	// screenActive mirrors the device screen state (pushed by the Android
	// SuspendModule; defaults to true so desktop and pre-signal starts keep the
	// previous behaviour). Unlike uiActive it stays true while the app is merely
	// backgrounded — it gates provider touching, not UI emits: lazy provider/group
	// health checks must keep running at their config interval while the user is
	// on the device (fallback groups go stale otherwise), and stop only when the
	// screen is dark.
	screenActive atomic.Bool
	// lastProviderTouchNs is the unix-nano time of the last touchProviders() run,
	// used by the screen-on catch-up to decide whether checks went dormant.
	lastProviderTouchNs atomic.Int64
)

// While the UI is backgrounded, keep proxy providers warm at this slow cadence
// (instead of minHealthCheckInterval) so url-test/fallback groups don't go stale,
// without spamming pings/UI updates.
const backgroundHealthCheckInterval = 5 * time.Minute

func handleInitClash(paramsString string) bool {
	var params = InitParams{}
	err := json.Unmarshal([]byte(paramsString), &params)
	if err != nil {
		return false
	}
	// EXPERIMENT: GC disabled entirely (was SetGCPercent(50)) — collections now
	// happen only when the heap reaches the soft memory limit below. This also
	// silences the runtime's forced 2-minute GC, so an idle core never wakes for
	// GC at all. Trade-off being evaluated: the heap floats up to the limit by
	// design, and under sustained traffic it parks there with limit-triggered
	// collections (the "GC wall"). If battery/CPU regresses, restore
	// SetGCPercent(50).
	debug.SetGCPercent(-1)
	// 70 MB soft limit (experiment; was 128, and 60 before that). History: a 60 MB
	// limit forced near-continuous GC — up to the runtime's 50%-CPU GC cap — when a
	// GEOIP/GEOSITE-heavy config's live heap sat close to it. 70 is back near that
	// regime on purpose, paired with GOGC=off: watch geo-heavy configs for the same
	// burn. With GOGC off this is the ONLY GC trigger left — never remove it, or
	// the heap grows unbounded until LMK/OOM.
	debug.SetMemoryLimit(70 * 1024 * 1024)
	version.Store(int32(params.Version))
	constant.SetHomeDir(params.HomeDir)
	// Default to "foreground": the main process drives setUiActive(false) when it
	// backgrounds. A headless cold-start has no UI but keeping the foreground
	// cadence here preserves the previous behaviour (no regression).
	uiActive.Store(true)
	// Screen assumed on until the SuspendModule pushes the real state.
	screenActive.Store(true)
	isInit.Store(true)
	return true
}

func handleStartListener() bool {
	runLock.Lock()
	if isRunning {
		runLock.Unlock()
		return true
	}
	isRunning = true
	if currentConfig != nil {
		// On Android TUN is driven by a file descriptor from VpnService in
		// handleStartTun, not by mihomo's internal TUN — keep cfg flag off.
		// On desktop, updateListeners() below will (re)create the TUN device.
		if runtime.GOOS == "android" {
			currentConfig.General.Tun.Enable = false
		} else {
			currentConfig.General.Tun.Enable = pendingTunEnable
		}
	}
	// setupConfig already ran executor.ApplyConfig when the profile was loaded,
	// so proxies/rules/DNS/providers are live. Starting only needs to (re)bind
	// listeners and (re)create the TUN device — calling ApplyConfig again would
	// re-run updateProxies, loadProvider(wg.Wait()), updateDNS and runtime.GC()
	// for no reason and was the main source of the long "start" delay.
	updateListeners()
	runLock.Unlock()

	go func() {
		resolver.ResetConnection()
		// handleShutdown/handleStopListener can win runLock in the window between
		// releasing it above and this goroutine running. Re-check under runLock
		// before (re)starting the forwarders so a lagging start can't revive them
		// after teardown (a leaked goroutine outliving shutdown). runLock is held
		// across startHealthCheckForwarder because that snapshots minHealthCheckInterval.
		runLock.Lock()
		if !isRunning || currentConfig == nil {
			runLock.Unlock()
			return
		}
		startHealthCheckForwarder()
		runLock.Unlock()
		// The request forwarder only feeds the connections UI; skip it while the
		// app is backgrounded (setUiActive(true) starts it when the UI returns).
		// startRequestForwarder re-checks isRunning under runLock itself.
		if uiActive.Load() {
			startRequestForwarder()
		}
	}()
	return true
}

func handleStopListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = false
	// Keep health-check forwarder running so proxy pings stay fresh in the UI
	// while the VPN is off. It is torn down only on full shutdown.
	stopRequestForwarder()
	stopListeners()
	return true
}

func handleGetIsInit() bool {
	return isInit.Load()
}

func handleForceGc() {
	go func() {
		log.Infoln("[APP] request force GC")
		runtime.GC()
	}()
}

func handleShutdown() bool {
	runLock.Lock()
	defer runLock.Unlock()
	stopHealthCheckForwarder()
	stopRequestForwarder()
	// Tear down the log subscription too: handleStartLog's subscription and pump
	// goroutine would otherwise leak across shutdown. handleStopLog is idempotent
	// and guarded by its own logMu (never takes runLock), so calling it here is safe.
	handleStopLog()
	stopListeners()
	executor.Shutdown()
	runtime.GC()
	isInit.Store(false)
	isRunning = false
	tunUp.Store(false)
	currentConfig = nil
	return true
}

func startHealthCheckForwarder() {
	// Reset the emit-dedup so the immediate warm-up emit below actually re-sends
	// the currently-known histories; otherwise a surviving signature (e.g. a
	// desktop stop->start where the executor lives on) is deduped and the UI shows
	// nothing until a value next changes.
	resetHealthCheckForwarderState()
	// setupConfig just ran runInitialProviderHealthChecks; stamp "fresh" so a
	// screen-on edge right after start doesn't fire a redundant catch-up sweep.
	lastProviderTouchNs.Store(time.Now().UnixNano())
	// Stop+recreate atomically under one lock hold. Two starts can overlap
	// (setupConfig and handleStartListener's goroutine, neither serialised by
	// runLock here); a separate stop()-then-create would let the second overwrite
	// healthCheckStopCh while the first goroutine keeps running on an unreferenced
	// channel that nothing can ever close — a leaked forwarder goroutine.
	healthCheckChMu.Lock()
	if healthCheckStopCh != nil {
		close(healthCheckStopCh)
	}
	healthCheckStopCh = make(chan struct{})
	stopCh := healthCheckStopCh
	healthCheckChMu.Unlock()
	// Snapshot minHealthCheckInterval here, where both callers (setupConfig and
	// handleStartListener's start goroutine) hold runLock, and pass it into the
	// goroutine. The global is written under runLock by computeMinHealthCheckInterval,
	// and a config change recomputes it then restarts this forwarder, so the snapshot
	// stays current — and the goroutine never reads the global without the lock.
	minInterval := minHealthCheckInterval
	go func(stopCh chan struct{}, minInterval time.Duration) {
		log.Infoln("[HealthCheck] forwarder fg interval: %s, bg interval: %s", minInterval, backgroundHealthCheckInterval)
		// Warm-up: surface pings the moment the tunnel comes up instead of after a
		// full interval. Emit immediately (re-sends surviving histories), then a few
		// quick follow-ups to catch the fresh url-tests setupConfig kicks off as they
		// complete. Offsets are cumulative (~0, 0.7s, 1.5s, 3s). Dedup keeps repeat
		// ticks cheap and emits are foreground-only.
		for _, d := range []time.Duration{0, 700 * time.Millisecond, 800 * time.Millisecond, 1500 * time.Millisecond} {
			select {
			case <-time.After(d):
				if uiActive.Load() {
					forwardHealthCheckDelays()
				}
			case <-stopCh:
				return
			}
		}
		for {
			// Recompute each cycle so foreground/background/screen transitions take
			// effect on the next tick without restarting the goroutine. Steady-state
			// cadence is the min group/provider interval from the config (minInterval);
			// only a dark screen (or an idle app with no tunnel) drops to the slow tick.
			interval := minInterval
			if !uiActive.Load() && !touchGateOpen() &&
				backgroundHealthCheckInterval > interval {
				interval = backgroundHealthCheckInterval
			}
			select {
			case <-time.After(interval):
				if uiActive.Load() {
					forwardHealthCheckDelays()
				} else if touchGateOpen() {
					// App backgrounded/killed but the screen is on and the tunnel is
					// up: keep touching so lazy provider/group health checks run at
					// their config interval — fallback/url-test groups must not go
					// stale (they keep routing into dead nodes otherwise). UI emits
					// stay foreground-only.
					touchProvidersSafely()
				}
				// Dark screen / no tunnel: do nothing. Real traffic re-warms
				// providers on demand (URLTest dial -> Touch); the screen-on edge
				// resweeps via handleSetScreenActive, and foreground return emits
				// immediately via handleSetUiActive.
			case <-stopCh:
				return
			}
		}
	}(stopCh, minInterval)
}

func stopHealthCheckForwarder() {
	healthCheckChMu.Lock()
	defer healthCheckChMu.Unlock()
	if healthCheckStopCh == nil {
		return
	}
	close(healthCheckStopCh)
	healthCheckStopCh = nil
}

func resetHealthCheckForwarderState() {
	healthCheckMu.Lock()
	healthCheckSeen = map[string]string{}
	healthCheckMu.Unlock()
}

func forwardHealthCheckDelays() {
	runLock.Lock()
	if currentConfig == nil {
		runLock.Unlock()
		return
	}
	touchProviders()
	proxies := proxiesWithProviders()
	runLock.Unlock()

	for name, proxy := range proxies {
		emitLatestDelay(name, "", proxy.DelayHistory())
		for url, state := range proxy.ExtraDelayHistories() {
			emitLatestDelay(name, url, state.History)
		}
	}
}

// runInitialProviderHealthChecks kicks off one HealthCheck per proxy provider
// in background goroutines, so the UI has pings right after profile load
// without waiting for the provider's own healthcheck-interval to elapse.
// HealthCheck blocks until every URL test finishes, so each provider gets
// its own goroutine to avoid serialising them.
func runInitialProviderHealthChecks() {
	for _, p := range tunnel.Providers() {
		pp, ok := p.(*provider.ProxySetProvider)
		if !ok {
			continue
		}
		go pp.HealthCheck()
	}
}

// touchProviders marks all proxy providers as recently used so that their
// internal lazy health-check goroutines actually execute on the next tick.
// Unlike the previous triggerProviderHealthChecks which called HealthCheck()
// (blocking until every URL test finishes), Touch() returns immediately and
// lets the provider's own background goroutine perform the checks without
// holding runLock for seconds.
//
// Deliberately unfiltered: tunnel.Providers() also contains the per-group
// CompatibleProviders that host url-test/fallback groups' own health checks
// (their url/interval from the config) — the old *ProxySetProvider filter left
// those untouched, so lazy group checks only ran when real traffic dialed
// through the group and fallback aliveness went stale on an idle tunnel.
func touchProviders() {
	for _, p := range tunnel.Providers() {
		p.Touch()
	}
	lastProviderTouchNs.Store(time.Now().UnixNano())
}

// touchGateOpen reports whether providers should be kept warm even though the
// UI is not foregrounded: the user is on the device (screen on) and the tunnel
// is up, so fallback/url-test aliveness must stay current for real traffic.
func touchGateOpen() bool {
	return screenActive.Load() && tunUp.Load()
}

// touchProvidersSafely is forwardHealthCheckDelays' touch step under runLock,
// without emitting delays — used to keep providers warm while the UI is hidden.
func touchProvidersSafely() {
	runLock.Lock()
	if currentConfig != nil {
		touchProviders()
	}
	runLock.Unlock()
}

// handleSetUiActive toggles the foreground flag. On the active->inactive edge it
// pauses the request forwarder; on inactive->active it restarts it (when a
// listener is running) and flushes current delays so the UI repopulates at once.
func handleSetUiActive(active bool) {
	// Don't early-return on an unchanged value: a headless-started tunnel can reach the
	// foreground with uiActive already true (no setUiActive(false) edge happened), and
	// we must still idempotently (re)arm the request forwarder and flush current delays.
	// startRequestForwarder/stopRequestForwarder are both no-ops when already in the
	// target state, so re-running on a redundant call is cheap.
	uiActive.Store(active)
	if active {
		runLock.Lock()
		running := isRunning
		runLock.Unlock()
		if running || tunUp.Load() {
			startRequestForwarder()
		}
		// Clear the health-check de-dup before flushing. While the tunnel ran headless
		// (tile/boot start, no UI listener attached) the forwarder's delay emits were
		// dropped by emitEvent (listener==nil) yet their signatures were still recorded
		// in healthCheckSeen — so a plain flush here would be fully de-duped and deliver
		// NOTHING to the just-attached UI (the "no pings after a tile start" bug). Reset
		// so the current delay histories re-emit on foreground.
		resetHealthCheckForwarderState()
		go forwardHealthCheckDelays()
	} else {
		stopRequestForwarder()
	}
}

// handleSetScreenActive tracks the device screen state (pushed by the Android
// SuspendModule). While the screen is on and the tunnel is up the forwarder
// keeps touching providers so lazy health checks run at their config interval
// even with the UI backgrounded or killed. On the off->on edge, if checks went
// dormant for at least one interval, force an immediate full sweep so
// fallback/url-test groups realign before the user starts browsing.
func handleSetScreenActive(active bool) {
	wasActive := screenActive.Swap(active)
	if !active || wasActive {
		return
	}
	if !tunUp.Load() && !uiActive.Load() {
		return
	}
	runLock.Lock()
	hasConfig := currentConfig != nil
	minInterval := minHealthCheckInterval
	runLock.Unlock()
	if !hasConfig {
		return
	}
	if time.Since(time.Unix(0, lastProviderTouchNs.Load())) < minInterval {
		return
	}
	log.Infoln("[HealthCheck] screen-on catch-up: forcing provider health checks")
	touchProvidersSafely()
	for _, p := range tunnel.Providers() {
		go p.HealthCheck()
	}
}

// startRequestForwarder polls the statistic manager for newly opened trackers
// and pushes each one to Flutter via a RequestMessage. Upstream mihomo does
// not expose the statistic.DefaultRequestNotify hook our old Clash.Meta fork
// relied on, so we emulate it with a short-interval poll.
func startRequestForwarder() {
	// Hold runLock across the start decision so a concurrent handleStopListener
	// (which clears isRunning and stops the forwarder under the same lock) can't
	// race us: either we start before the stop, or we observe the cleared flag and
	// don't revive a forwarder for a listener that's no longer running. Callers
	// (handleStartListener's goroutine, handleSetUiActive) never hold runLock here.
	runLock.Lock()
	defer runLock.Unlock()
	// isRunning covers an app-driven start (startListener); tunUp covers a headless
	// tile/boot start (Core.startTun without startListener). Either means the tunnel is
	// up and the connections it carries should feed the Journal.
	if !isRunning && !tunUp.Load() {
		return
	}
	requestChMu.Lock()
	if requestStopCh != nil {
		requestChMu.Unlock()
		return
	}
	requestMu.Lock()
	requestSeen = map[string]bool{}
	requestMu.Unlock()
	requestStopCh = make(chan struct{})
	stopCh := requestStopCh
	requestChMu.Unlock()
	go func(stopCh chan struct{}) {
		// 4s (was 2s): this only feeds the Requests live-log; halving the poll rate
		// halves the foreground O(connections) scan + IPC churn that runs even when
		// that page isn't open, with no user-visible loss on a log view.
		ticker := time.NewTicker(4 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				forwardNewRequests()
			case <-stopCh:
				return
			}
		}
	}(stopCh)
}

func stopRequestForwarder() {
	requestChMu.Lock()
	defer requestChMu.Unlock()
	if requestStopCh == nil {
		return
	}
	close(requestStopCh)
	requestStopCh = nil
	requestMu.Lock()
	requestSeen = map[string]bool{}
	requestMu.Unlock()
}

func forwardNewRequests() {
	requestMu.Lock()
	defer requestMu.Unlock()
	alive := make(map[string]bool, len(requestSeen))
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		id := c.ID()
		alive[id] = true
		if requestSeen[id] {
			return true
		}
		requestSeen[id] = true
		sendMessage(Message{
			Type: RequestMessage,
			Data: c.Info(),
		})
		return true
	})
	for id := range requestSeen {
		if !alive[id] {
			delete(requestSeen, id)
		}
	}
}

func emitLatestDelay(proxyName string, testURL string, history []constant.DelayHistory) {
	if len(history) == 0 {
		return
	}
	latest := history[len(history)-1]
	key := proxyName + "|" + testURL
	signature := fmt.Sprintf("%d:%d", latest.Time.UnixNano(), latest.Delay)
	healthCheckMu.Lock()
	if healthCheckSeen[key] == signature {
		healthCheckMu.Unlock()
		return
	}
	healthCheckSeen[key] = signature
	healthCheckMu.Unlock()

	delayValue := int32(latest.Delay)
	if latest.Delay == 0 {
		delayValue = -1
	}
	sendMessage(Message{
		Type: DelayMessage,
		Data: &Delay{
			Url:   testURL,
			Name:  proxyName,
			Value: delayValue,
		},
	})
}

func handleValidateConfig(bytes []byte) string {
	_, err := config.UnmarshalRawConfig(bytes)
	if err != nil {
		return err.Error()
	}
	return ""
}

func handleGetProxies() interface{} {
	runLock.Lock()
	defer runLock.Unlock()
	return proxiesWithDescriptions()
}

func handleChangeProxy(data string, fn func(string string)) {
	go func() {
		var params = &ChangeProxyParams{}
		err := json.Unmarshal([]byte(data), params)
		if err != nil {
			fn(err.Error())
			return
		}
		if params.GroupName == nil || params.ProxyName == nil {
			fn("missing group-name or proxy-name")
			return
		}
		groupName := *params.GroupName
		proxyName := *params.ProxyName

		// Hold runLock only across the proxy lookup + selector mutation, then
		// release it BEFORE invoking fn (a JNI upcall): calling into the JVM while
		// holding runLock risks a re-entrant deadlock. Acquire and release on this
		// same goroutine — the old code locked on the caller and unlocked here, a
		// cross-goroutine handoff.
		runLock.Lock()
		proxies := proxiesWithProviders()
		group, ok := proxies[groupName]
		if !ok {
			runLock.Unlock()
			fn("Not found group")
			return
		}
		adapterProxy, ok := group.(*adapter.Proxy)
		if !ok {
			runLock.Unlock()
			fn("Group is not a proxy adapter")
			return
		}
		selector, ok := adapterProxy.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			runLock.Unlock()
			fn("Group is not selectable")
			return
		}
		if proxyName == "" {
			selector.ForceSet(proxyName)
		} else {
			err = selector.Set(proxyName)
		}
		runLock.Unlock()
		if err != nil {
			fn(err.Error())
			return
		}

		fn("")
	}()
}

func handleGetTraffic() string {
	up, down := statistic.DefaultManager.Now()
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		log.Errorln("Error: %v", err)
		return ""
	}
	return string(data)
}

func handleGetTotalTraffic() string {
	up, down := statistic.DefaultManager.Total()
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		log.Errorln("Error: %v", err)
		return ""
	}
	return string(data)
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleAsyncTestDelay(paramsString string, fn func(string)) {
	// Async, capped at 50 concurrent tests. Replaces a process-wide batch.Batch
	// whose result map was never drained (slow retention + dead cancel/err state);
	// a plain weighted semaphore preserves the concurrency cap and the
	// returns-immediately contract without retaining anything.
	go func() {
		_ = testDelaySem.Acquire(context.Background(), 1) // never errors with Background
		defer testDelaySem.Release(1)

		var params = &TestDelayParams{}
		err := json.Unmarshal([]byte(paramsString), params)
		if err != nil {
			fn("")
			return
		}

		expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
		if err != nil {
			fn("")
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(params.Timeout))
		defer cancel()

		proxies := proxiesWithProviders()
		proxy := proxies[params.ProxyName]

		delayData := &Delay{
			Name: params.ProxyName,
		}

		if proxy == nil {
			delayData.Value = -1
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return
		}

		testUrl := "https://www.gstatic.com/generate_204"

		if params.TestUrl != "" {
			testUrl = params.TestUrl
		}
		delayData.Url = testUrl

		delay, err := proxy.URLTest(ctx, testUrl, expectedStatus)
		if err != nil || delay == 0 {
			delayData.Value = -1
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return
		}

		delayData.Value = int32(delay)
		data, _ := json.Marshal(delayData)
		fn(string(data))

		// Push delay update via message
		sendMessage(Message{
			Type: DelayMessage,
			Data: delayData,
		})
	}()
}

func handleGetConnections() string {
	runLock.Lock()
	defer runLock.Unlock()
	snapshot := statistic.DefaultManager.Snapshot()
	data, err := json.Marshal(snapshot)
	if err != nil {
		log.Errorln("Error: %v", err)
		return ""
	}
	return string(data)
}

func handleCloseConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	closeConnections()
	return true
}

func closeConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func handleResetConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	resolver.ResetConnection()
	return true
}

func handleCloseConnection(connectionId string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}

func handleGetExternalProviders() string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProviders = getExternalProvidersRaw()
	eps := make([]ExternalProvider, 0)
	for _, p := range externalProviders {
		externalProvider, err := toExternalProvider(p)
		if err != nil {
			continue
		}
		eps = append(eps, *externalProvider)
	}
	sort.Sort(ExternalProviders(eps))
	data, err := json.Marshal(eps)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleGetExternalProvider(externalProviderName string) string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProvider, exist := externalProviders[externalProviderName]
	if !exist {
		return ""
	}
	e, err := toExternalProvider(externalProvider)
	if err != nil {
		return ""
	}
	data, err := json.Marshal(e)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleUpdateGeoData(geoType string, geoName string, fn func(value string)) {
	go func() {
		var err error
		switch geoType {
		case "MMDB":
			err = updater.UpdateMMDB()
		case "ASN":
			err = updater.UpdateASN()
		case "GeoIp":
			err = updater.UpdateGeoIp()
		case "GeoSite":
			err = updater.UpdateGeoSite()
		}
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleUpdateExternalProvider(providerName string, fn func(value string)) {
	go func() {
		runLock.Lock()
		externalProvider, exist := externalProviders[providerName]
		runLock.Unlock()
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := externalProvider.Update()
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleSideLoadExternalProvider(providerName string, data []byte, fn func(value string)) {
	go func() {
		// Snapshot the provider under runLock, then release it before the update and
		// the fn (JNI) callback — mirrors handleUpdateExternalProvider and keeps the
		// upcall off the lock. (externalProviders is only mutated under runLock.)
		runLock.Lock()
		externalProvider, exist := externalProviders[providerName]
		runLock.Unlock()
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := sideUpdateExternalProvider(externalProvider, data)
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

var logMu sync.Mutex

func handleStartLog() {
	logMu.Lock()
	defer logMu.Unlock()
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
	logSubscriber = log.Subscribe()
	sub := logSubscriber
	go func() {
		for logData := range sub {
			if logData.LogLevel < log.Level() {
				continue
			}
			if strings.Contains(logData.Payload, "http: Server closed") {
				continue
			}
			// Don't marshal + cross-process IPC every log line to a UI nobody is
			// watching: while the app is backgrounded the log view isn't visible, so
			// forwarding under the standby wakelock is wasted CPU/IPC. (The channel is
			// still drained, so there's no backpressure on the core's logger.)
			if !uiActive.Load() {
				continue
			}
			message := &Message{
				Type: LogMessage,
				Data: logData,
			}
			sendMessage(*message)
		}
	}()
}

func handleStopLog() {
	logMu.Lock()
	defer logMu.Unlock()
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
}

func handleGetCountryCode(ip string, fn func(value string)) {
	go func() {
		// Look up under runLock, release, then call fn (a JNI upcall) outside the
		// lock to avoid a re-entrant deadlock through the JVM callback.
		runLock.Lock()
		codes := mmdb.IPInstance().LookupCode(net.ParseIP(ip))
		runLock.Unlock()
		if len(codes) == 0 {
			fn("")
			return
		}
		fn(codes[0])
	}()
}

func handleGetMemory(fn func(value string)) {
	go func() {
		fn(strconv.FormatUint(statistic.DefaultManager.Memory(), 10))
	}()
}

func handleSetState(params string) {
	runLock.Lock()
	defer runLock.Unlock()
	if err := json.Unmarshal([]byte(params), state.CurrentState); err != nil {
		log.Warnln("[State] unmarshal failed: %v", err)
	}
}

func handleGetConfig(path string) (*config.RawConfig, error) {
	bytes, err := readFile(path)
	if err != nil {
		return nil, err
	}
	prof, err := config.UnmarshalRawConfig(bytes)
	if err != nil {
		return nil, err
	}
	return prof, nil
}

func handleHealthCheck(groupName string, fn func(value string)) {
	runLock.Lock()
	testUrl := currentTestURL
	runLock.Unlock()
	go func() {
		proxies := tunnel.Proxies()
		expectedStatus, _ := utils.NewUnsignedRanges[uint16]("")
		defaultUrl := testUrl

		for name, proxy := range proxies {
			if groupName != "" && name != groupName {
				continue
			}
			group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
			if !ok {
				continue
			}
			testUrl := ""
			for _, p := range group.Providers() {
				if u := p.HealthCheckURL(); u != "" {
					testUrl = u
					break
				}
			}
			if testUrl == "" {
				testUrl = defaultUrl
			}
			log.Infoln("[HealthCheck] testing group: %s url: %s", name, testUrl)
			for _, p := range group.Providers() {
				for _, px := range p.Proxies() {
					sendMessage(Message{
						Type: DelayMessage,
						Data: &Delay{Url: testUrl, Name: px.Name(), Value: 0},
					})
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			dm, err := group.URLTest(ctx, testUrl, expectedStatus)
			cancel()
			if err != nil {
				log.Warnln("[HealthCheck] group %s error: %v", name, err)
				continue
			}
			for proxyName, delay := range dm {
				sendMessage(Message{
					Type: DelayMessage,
					Data: &Delay{Url: testUrl, Name: proxyName, Value: int32(delay)},
				})
			}
			log.Infoln("[HealthCheck] group %s done, %d results", name, len(dm))
		}
		fn("")
	}()
}

// handleHealthProbe is a cheap liveness probe for the background watchdog: a
// SINGLE generate_204 through the currently-selected GLOBAL outbound, instead of
// URL-testing every proxy in every group (which woke the radio to ping the whole
// node list every cycle). Calls fn("ok") on success and fn("") on failure/timeout
// (the Kotlin watchdog treats non-"ok" as a failed cycle and resets connections).
// fn is always called so the JNI callback global ref is released.
func handleHealthProbe(fn func(value string)) {
	runLock.Lock()
	testUrl := currentTestURL
	hasConfig := currentConfig != nil
	runLock.Unlock()
	if !hasConfig {
		fn("")
		return
	}
	go func() {
		active := tunnel.Proxies()["GLOBAL"]
		if active == nil {
			fn("")
			return
		}
		expectedStatus, _ := utils.NewUnsignedRanges[uint16]("")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		delay, err := active.URLTest(ctx, testUrl, expectedStatus)
		if err != nil || delay == 0 {
			fn("")
			return
		}
		fn("ok")
	}()
}

func handleCrash() {
	panic("handle invoke crash")
}

func handleUpdateConfig(bytes []byte) string {
	var params = &UpdateParams{}
	err := json.Unmarshal(bytes, params)
	if err != nil {
		return err.Error()
	}
	updateConfig(params)
	return ""
}

func handleSetupConfig(bytes []byte) string {
	var params = defaultSetupParams()
	err := UnmarshalJson(bytes, params)
	if err != nil {
		log.Errorln("unmarshalRawConfig error %v", err)
		_ = setupConfig(defaultSetupParams())
		return err.Error()
	}
	err = setupConfig(params)
	if err != nil {
		return err.Error()
	}
	return ""
}
