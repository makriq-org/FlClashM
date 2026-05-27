package main

import (
	b "bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"runtime"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/batch"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	currentConfig     *config.Config
	version           = 0
	isRunning         = false
	runLock           sync.Mutex
	mBatch, _         = batch.New[bool](context.Background(), batch.WithConcurrencyNum[bool](50))
	proxyDescMu       sync.RWMutex
	proxyDescriptions = map[string]string{}
	pendingTunEnable      = false
	currentTestURL        = "https://www.gstatic.com/generate_204"
	minHealthCheckInterval = 5 * time.Second
)

type ExternalProviders []ExternalProvider

func (a ExternalProviders) Len() int           { return len(a) }
func (a ExternalProviders) Less(i, j int) bool { return a[i].Name < a[j].Name }
func (a ExternalProviders) Swap(i, j int)      { a[i], a[j] = a[j], a[i] }

// proxiesWithProviders merges proxies from tunnel and all proxy providers
func proxiesWithProviders() map[string]constant.Proxy {
	allProxies := make(map[string]constant.Proxy)
	for name, proxy := range tunnel.Proxies() {
		allProxies[name] = proxy
	}
	for _, p := range tunnel.Providers() {
		for _, proxy := range p.Proxies() {
			name := proxy.Name()
			allProxies[name] = proxy
		}
	}
	return allProxies
}

func computeMinHealthCheckInterval(rawConfig *config.RawConfig) {
	min := 300
	for _, g := range rawConfig.ProxyGroup {
		var iv int
		switch v := g["interval"].(type) {
		case int:
			iv = v
		case float64:
			iv = int(v)
		case json.Number:
			iv64, _ := v.Int64()
			iv = int(iv64)
		}
		if iv > 0 && iv < min {
			min = iv
		}
	}
	d := time.Duration(min) * time.Second
	if d < 5*time.Second {
		d = 5 * time.Second
	}
	log.Infoln("[HealthCheck] computed min interval from %d groups: %s", len(rawConfig.ProxyGroup), d)
	minHealthCheckInterval = d
}

// extractProxyDescriptionsFromRaw caches custom server descriptions by proxy name.
func extractProxyDescriptionsFromRaw(rawConfig *config.RawConfig) {
	descriptions := make(map[string]string, len(rawConfig.Proxy))
	for _, proxy := range rawConfig.Proxy {
		nameValue, ok := proxy["name"]
		if !ok {
			continue
		}
		name, ok := nameValue.(string)
		if !ok || name == "" {
			continue
		}
		description := ""
		if value, ok := proxy["serverDescription"]; ok {
			if text, ok := value.(string); ok {
				description = text
			}
		}
		if description == "" {
			if value, ok := proxy["server-description"]; ok {
				if text, ok := value.(string); ok {
					description = text
				}
			}
		}
		if description == "" {
			continue
		}
		descriptions[name] = description
	}
	proxyDescMu.Lock()
	proxyDescriptions = descriptions
	proxyDescMu.Unlock()
}

// proxiesWithDescriptions injects serverDescription for each proxy in API response.
func proxiesWithDescriptions() map[string]interface{} {
	result := make(map[string]interface{})
	for name, proxy := range proxiesWithProviders() {
		data, err := json.Marshal(proxy)
		if err != nil {
			continue
		}
		item := make(map[string]interface{})
		if err := json.Unmarshal(data, &item); err != nil {
			continue
		}
		proxyDescMu.RLock()
		desc, hasDesc := proxyDescriptions[name]
		proxyDescMu.RUnlock()
		if hasDesc && desc != "" {
			item["serverDescription"] = desc
		}
		result[name] = item
	}
	return result
}

func getExternalProvidersRaw() map[string]cp.Provider {
	eps := make(map[string]cp.Provider)
	for n, p := range tunnel.Providers() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	for n, p := range tunnel.RuleProviders() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	return eps
}

func toExternalProvider(p cp.Provider) (*ExternalProvider, error) {
	switch pp := p.(type) {
	case *provider.ProxySetProvider:
		// Get SubscriptionInfo via JSON marshal (field is unexported in original mihomo)
		var subInfo *provider.SubscriptionInfo
		data, err := json.Marshal(pp)
		if err == nil {
			var apiData struct {
				SubscriptionInfo *provider.SubscriptionInfo `json:"subscriptionInfo"`
			}
			_ = json.Unmarshal(data, &apiData)
			subInfo = apiData.SubscriptionInfo
		}
		return &ExternalProvider{
			Name:             pp.Name(),
			Type:             pp.Type().String(),
			VehicleType:      pp.VehicleType().String(),
			Count:            pp.Count(),
			UpdateAt:         pp.UpdatedAt(),
			Path:             pp.Vehicle().Path(),
			SubscriptionInfo: subInfo,
		}, nil
	case *rp.RuleSetProvider:
		return &ExternalProvider{
			Name:        pp.Name(),
			Type:        pp.Type().String(),
			VehicleType: pp.VehicleType().String(),
			Count:       pp.Count(),
			UpdateAt:    pp.UpdatedAt(),
			Path:        pp.Vehicle().Path(),
		}, nil
	default:
		return nil, errors.New("not external provider")
	}
}

func sideUpdateExternalProvider(p cp.Provider, bytes []byte) error {
	switch pp := p.(type) {
	case *provider.ProxySetProvider:
		_, _, err := pp.SideUpdate(bytes)
		if err != nil {
			return err
		}
		return nil
	case *rp.RuleSetProvider:
		_, _, err := pp.SideUpdate(bytes)
		if err != nil {
			return err
		}
		return nil
	default:
		return errors.New("not external provider")
	}
}

// updateListeners recreates all listeners from current config
func updateListeners() {
	if !isRunning {
		return
	}
	if currentConfig == nil {
		return
	}
	listeners := currentConfig.Listeners
	general := currentConfig.General
	listener.PatchInboundListeners(listeners, tunnel.Tunnel, true)
	listener.SetAllowLan(general.AllowLan)
	inbound.SetSkipAuthPrefixes(general.SkipAuthPrefixes)
	inbound.SetAllowedIPs(general.LanAllowedIPs)
	inbound.SetDisAllowedIPs(general.LanDisAllowedIPs)
	listener.SetBindAddress(general.BindAddress)
	listener.ReCreateHTTP(general.Port, tunnel.Tunnel)
	listener.ReCreateSocks(general.SocksPort, tunnel.Tunnel)
	listener.ReCreateRedir(general.RedirPort, tunnel.Tunnel)
	listener.ReCreateTProxy(general.TProxyPort, tunnel.Tunnel)
	listener.ReCreateMixed(general.MixedPort, tunnel.Tunnel)
	listener.ReCreateShadowSocks(general.ShadowSocksConfig, tunnel.Tunnel)
	listener.ReCreateVmess(general.VmessConfig, tunnel.Tunnel)
	listener.ReCreateTuic(general.TuicServer, tunnel.Tunnel)
	// Desktop builds may include the `cmfa` tag, so gate TUN only on Android.
	if runtime.GOOS != "android" {
		listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	}
}

// stopListeners stops all active listeners
func stopListeners() {
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	listener.ReCreateTuic(LC.TuicServer{}, tunnel.Tunnel)
	if runtime.GOOS != "android" {
		listener.ReCreateTun(LC.Tun{}, tunnel.Tunnel)
	}
	listener.Cleanup()
}

func patchSelectGroup(mapping map[string]string) {
	for name, proxy := range proxiesWithProviders() {
		outbound, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}

		selector, ok := outbound.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			continue
		}

		selected, exist := mapping[name]
		if !exist {
			continue
		}

		selector.ForceSet(selected)
	}
}

func defaultSetupParams() *SetupParams {
	return &SetupParams{
		Config:      config.DefaultRawConfig(),
		TestURL:     "https://www.gstatic.com/generate_204",
		SelectedMap: map[string]string{},
	}
}

func readFile(path string) ([]byte, error) {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	return data, err
}

func updateConfig(params *UpdateParams) {
	runLock.Lock()
	defer runLock.Unlock()
	if currentConfig == nil {
		return
	}
	general := currentConfig.General
	if params.MixedPort != nil {
		general.MixedPort = *params.MixedPort
	}
	if params.Sniffing != nil {
		general.Sniffing = *params.Sniffing
		tunnel.SetSniffing(general.Sniffing)
	}
	if params.FindProcessMode != nil {
		general.FindProcessMode = *params.FindProcessMode
		tunnel.SetFindProcessMode(general.FindProcessMode)
	}
	if params.TCPConcurrent != nil {
		general.TCPConcurrent = *params.TCPConcurrent
		dialer.SetTcpConcurrent(general.TCPConcurrent)
	}
	if params.Interface != nil {
		general.Interface = *params.Interface
		dialer.DefaultInterface.Store(general.Interface)
	}
	if params.UnifiedDelay != nil {
		general.UnifiedDelay = *params.UnifiedDelay
		adapter.UnifiedDelay.Store(general.UnifiedDelay)
	}
	if params.Mode != nil {
		general.Mode = *params.Mode
		tunnel.SetMode(general.Mode)
	}
	if params.LogLevel != nil {
		general.LogLevel = *params.LogLevel
		log.SetLevel(general.LogLevel)
	}
	if params.IPv6 != nil {
		general.IPv6 = *params.IPv6
		resolver.DisableIPv6 = !general.IPv6
	}
	if params.ExternalController != nil {
		currentConfig.Controller.ExternalController = *params.ExternalController
		if currentConfig.Controller.ExternalUI != "" {
			route.SetUIPath(currentConfig.Controller.ExternalUI)
		}
		route.ReCreateServer(&route.Config{
			Addr: currentConfig.Controller.ExternalController,
		})
	}

	if params.Tun != nil {
		general.Tun.Enable = params.Tun.Enable
		pendingTunEnable = params.Tun.Enable
		if params.Tun.AutoRoute != nil {
			general.Tun.AutoRoute = *params.Tun.AutoRoute
		}
		if params.Tun.Device != nil {
			general.Tun.Device = *params.Tun.Device
		}
		if params.Tun.RouteAddress != nil {
			general.Tun.RouteAddress = *params.Tun.RouteAddress
		}
		if params.Tun.DNSHijack != nil {
			general.Tun.DNSHijack = *params.Tun.DNSHijack
		}
		if params.Tun.Stack != nil {
			general.Tun.Stack = *params.Tun.Stack
		}
	}

	updateListeners()
}

func setupConfig(params *SetupParams) error {
	runLock.Lock()
	defer runLock.Unlock()
	var err error

	extractProxyDescriptionsFromRaw(params.Config)
	computeMinHealthCheckInterval(params.Config)
	resetHealthCheckForwarderState()
	if params.TestURL != "" {
		currentTestURL = params.TestURL
	}

	parseStart := time.Now()
	currentConfig, err = config.ParseRawConfig(params.Config)
	if err != nil {
		log.Errorln("[Config] ParseRawConfig failed, falling back to default: %v", err)
		currentConfig, _ = config.ParseRawConfig(config.DefaultRawConfig())
	}
	log.Infoln("[Setup] ParseRawConfig took %s", time.Since(parseStart))
	pendingTunEnable = currentConfig.General.Tun.Enable
	if runtime.GOOS == "android" || !isRunning {
		currentConfig.General.Tun.Enable = false
	}
	applyStart := time.Now()
	executor.ApplyConfig(currentConfig, true)
	log.Infoln("[Setup] executor.ApplyConfig took %s", time.Since(applyStart))
	go runtime.GC()
	currentConfig.General.Tun.Enable = pendingTunEnable
	// External-controller lifecycle is independent from TUN start/stop.
	// Recreate API server during setup so it survives app restarts without
	// requiring a manual UI toggle.
	if currentConfig.Controller.ExternalUI != "" {
		route.SetUIPath(currentConfig.Controller.ExternalUI)
	}
	route.ReCreateServer(&route.Config{
		Addr: currentConfig.Controller.ExternalController,
	})
	patchSelectGroup(params.SelectedMap)
	updateListeners()

	// Kick off pings immediately so the UI shows latencies as soon as the
	// profile loads, without waiting for the user to start TUN or for each
	// provider's own healthcheck-interval to elapse. The forwarder is started
	// here (not only on Start) and keeps running until shutdown.
	runInitialProviderHealthChecks()
	startHealthCheckForwarder()

	// Notify Flutter that all providers are loaded
	sendMessage(Message{
		Type: LoadedMessage,
		Data: "all",
	})

	return err
}

func UnmarshalJson(data []byte, v any) error {
	decoder := json.NewDecoder(b.NewReader(data))
	decoder.UseNumber()
	err := decoder.Decode(v)
	return err
}
