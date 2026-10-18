package main

import (
	"bytes"
	"context"
	"core/backend"
	prepare "core/backend/compile"
	"core/backend/host"
	application "core/backend/service"
	"core/backend/transport"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/inner"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func backendTLSConfig(roots *x509.CertPool) *tls.Config {
	return &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
}

// Android's service process is the only composition root. The UI cannot supply
// executable paths, capabilities or compiled plans to the application API.
var applicationMu sync.Mutex
var applicationBackend *application.App
var backendManaged atomic.Bool
var platformBroker = &host.Broker{Send: func(request host.Request) {
	sendMessage(Message{Type: "backendPlatform", Data: request})
}}

type backendHostOptions struct {
	Home          string            `json:"home"`
	SDK           int               `json:"sdk"`
	ABI           string            `json:"abi"`
	Package       string            `json:"package"`
	Executables   map[string]string `json:"executables"`
	Legacy        json.RawMessage   `json:"legacy"`
	LegacyRunning bool              `json:"legacyRunning"`
	TimeZone      string            `json:"timeZone"`
	UTCOffset     int               `json:"utcOffset"`
	UserAgent     string            `json:"userAgent"`
	Certificates  []string          `json:"certificates"`
}

func handleBackendAction(action *Action, result ActionResult) bool {
	switch action.Method {
	case "backend.platform.complete":
		var response host.Result
		raw, _ := json.Marshal(action.Data)
		if err := json.Unmarshal(raw, &response); err != nil {
			result.error(err.Error())
		} else {
			result.success(platformBroker.Complete(response))
		}
		return true
	case "backend.open":
		var options backendHostOptions
		raw, _ := json.Marshal(action.Data)
		if err := json.Unmarshal(raw, &options); err != nil {
			result.error(err.Error())
			return true
		}
		if err := openApplicationBackend(options); err != nil {
			result.error(err.Error())
		} else {
			result.success(true)
		}
		return true
	case "backend.validate":
		// Only the isolated :validator host dispatches this privileged action.
		var request struct {
			Home string `json:"home"`
			Path string `json:"path"`
		}
		raw, _ := json.Marshal(action.Data)
		if err := json.Unmarshal(raw, &request); err != nil {
			result.error(err.Error())
			return true
		}
		result.success(validateIsolatedFile(request.Home, request.Path))
		return true
	case "backend":
		applicationMu.Lock()
		app := applicationBackend
		applicationMu.Unlock()
		if app == nil {
			result.error("backend is not ready")
			return true
		}
		var raw []byte
		if text, ok := action.Data.(string); ok {
			raw = []byte(text)
		} else {
			raw, _ = json.Marshal(action.Data)
		}
		result.success(json.RawMessage(app.Handle(raw)))
		return true
	case "backend.host.event":
		var event backend.PlatformEvent
		raw, _ := json.Marshal(action.Data)
		if err := json.Unmarshal(raw, &event); err != nil {
			result.error(err.Error())
			return true
		}
		applicationMu.Lock()
		app := applicationBackend
		applicationMu.Unlock()
		if app == nil {
			result.error("backend is not ready")
			return true
		}
		if err := app.NotifyPlatform(event); err != nil {
			result.error(err.Error())
		} else {
			result.success(true)
		}
		return true
	}
	return false
}

func openApplicationBackend(options backendHostOptions) error {
	applicationMu.Lock()
	defer applicationMu.Unlock()
	if applicationBackend != nil {
		return nil
	}
	if !filepath.IsAbs(options.Home) || options.Package != "com.makriq.flclash" {
		return errors.New("invalid backend host")
	}
	initParams, _ := json.Marshal(InitParams{HomeDir: options.Home, Version: options.SDK})
	if !handleInitClash(string(initParams)) {
		return errors.New("core initialization failed")
	}
	uiActive.Store(false)
	roots, _ := x509.SystemCertPool()
	if roots == nil {
		roots = x509.NewCertPool()
	}
	for _, encoded := range options.Certificates {
		der, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return errors.New("invalid host certificate")
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return err
		}
		roots.AddCert(cert)
	}
	client := &http.Client{Timeout: 2 * time.Minute, Transport: &http.Transport{
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if tunUp.Load() {
				return inner.HandleTcp(tunnel.Tunnel, address, "")
			}
			return (&net.Dialer{}).DialContext(ctx, network, address)
		},
		TLSClientConfig: backendTLSConfig(roots),
	}}
	lists := &prepare.ListStore{Home: options.Home, RootCAs: roots}
	compiler := &prepare.Compiler{
		Capabilities: prepare.Capabilities{Platform: "android", HomeDir: options.Home, ProfilesDir: filepath.Join(options.Home, "profiles"), SelfPackages: []string{options.Package}, InstalledPackages: func(ctx context.Context) ([]string, error) {
			var packages []string
			err := platformBroker.Call(ctx, "packages.list", nil, &packages)
			return packages, err
		}},
		Scripts: prepare.JavaScript{}, Nodes: &prepare.ExternalCompiler{RemoteLists: lists}, Lists: backendPackageLists{client},
		Validate: func(ctx context.Context, value prepare.Object) error {
			return validateThroughHost(ctx, options.Home, value)
		},
	}
	probe := &transport.SOCKSProbe{RootCAs: roots}
	nodes := &transport.ProcessAdapter{Home: options.Home, ABI: options.ABI, Executables: options.Executables, ProbeRequest: probe.Probe, PhysicalDNS: func(ctx context.Context) ([]netip.Addr, error) {
		var values []string
		if err := platformBroker.Call(ctx, "network.dns", nil, &values); err != nil {
			return nil, err
		}
		addresses := make([]netip.Addr, 0, len(values))
		for _, v := range values {
			if ip, e := netip.ParseAddr(v); e == nil {
				addresses = append(addresses, ip)
			}
		}
		return addresses, nil
	}}
	zone, err := time.LoadLocation(options.TimeZone)
	if err != nil {
		zone = time.FixedZone("legacy", options.UTCOffset)
	}
	backendManaged.Store(true)
	app, err := application.Open(application.Options{
		Directory: filepath.Join(options.Home, "backend"), LegacySettings: options.Legacy, LegacyRunning: options.LegacyRunning, LegacyTimeZone: options.TimeZone, LegacyUTCOffset: options.UTCOffset,
		Compiler: compiler, ValidateSource: func(ctx context.Context, source string) error {
			// Validation uses exactly the normal preparation pipeline, without
			// installing a plan or starting a process.
			input, _ := json.Marshal(prepare.Input{Version: 1, Profile: &prepare.RawProfile{ID: "validation", Text: source}, Settings: prepare.Object{}})
			_, err := compiler.Compile(ctx, input, 1)
			return err
		},
		Engine: backendEngine{probe: probe}, Platform: backendPlatform{}, Nodes: backend.NodeOptions{Adapter: nodes, Inspection: backendInspection{}, Cache: &transport.CacheStore{Home: options.Home, ABI: options.ABI, LegacyTimeZone: zone}, ABI: options.ABI},
		HTTPClient: client, UserAgent: options.UserAgent, DeviceHeaders: func(ctx context.Context) (map[string]string, error) {
			var values map[string]string
			err := platformBroker.Call(ctx, "device.headers", nil, &values)
			return values, err
		},
	})
	if err != nil {
		backendManaged.Store(false)
		return err
	}
	applicationBackend = app
	_, events, _ := app.Subscribe(1)
	go func() {
		for event := range events {
			sendMessage(Message{Type: "backend", Data: event})
		}
	}()
	return nil
}

func validateThroughHost(ctx context.Context, home string, config prepare.Object) error {
	root := filepath.Join(home, "backend", "validation")
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(root, "config-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	raw, err := json.Marshal(config)
	if err == nil {
		_, err = file.Write(raw)
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return platformBroker.Call(ctx, "engine.validate", map[string]string{"path": file.Name()}, nil)
}

func validateIsolatedFile(home, path string) string {
	root, err := filepath.EvalSymlinks(filepath.Join(home, "backend", "validation"))
	if err != nil {
		return err.Error()
	}
	name, err := filepath.EvalSymlinks(path)
	if err != nil {
		return err.Error()
	}
	if filepath.Dir(name) != root || !strings.HasPrefix(filepath.Base(name), "config-") {
		return "invalid validation path"
	}
	file, err := os.Open(name)
	if err != nil {
		return err.Error()
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, 32<<20+1))
	if err != nil {
		return err.Error()
	}
	if len(raw) > 32<<20 {
		return "configuration too large"
	}
	constant.SetHomeDir(home)
	parsed, err := config.UnmarshalRawConfig(raw)
	if err != nil {
		return err.Error()
	}
	_, err = config.ParseRawConfig(parsed)
	if err != nil {
		return err.Error()
	}
	return ""
}

type backendEngine struct{ probe *transport.SOCKSProbe }

func (backendEngine) Apply(ctx context.Context, plan *backend.RuntimePlan) error {
	var payload struct {
		Config   json.RawMessage   `json:"config"`
		Selected map[string]string `json:"selected-map"`
		TestURL  string            `json:"test-url"`
		State    json.RawMessage   `json:"coreState"`
	}
	if err := json.Unmarshal(plan.Payload(), &payload); err != nil {
		return err
	}
	raw, err := config.UnmarshalRawConfig(payload.Config)
	if err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = setupConfigWithContext(ctx, &SetupParams{Config: raw, SelectedMap: payload.Selected, TestURL: payload.TestURL}, false); err != nil {
		return err
	}
	handleSetState(string(payload.State))
	return ctx.Err()
}
func (backendEngine) ApplySelection(ctx context.Context, old, next *backend.RuntimePlan) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var payload struct {
		Selected map[string]string `json:"selected-map"`
		State    json.RawMessage   `json:"coreState"`
	}
	if err := json.Unmarshal(next.Payload(), &payload); err != nil {
		return err
	}
	var before struct {
		Selected map[string]string `json:"selected-map"`
	}
	if err := json.Unmarshal(old.Payload(), &before); err != nil {
		return err
	}
	runLock.Lock()
	proxies := proxiesWithProviders()
	for group, selected := range payload.Selected {
		if before.Selected[group] == selected {
			continue
		}
		proxy := proxies[group]
		if proxy == nil {
			runLock.Unlock()
			return errors.New("unknown proxy group")
		}
		selector, ok := proxy.Adapter().(outboundgroup.SelectAble)
		if !ok {
			runLock.Unlock()
			return errors.New("proxy group cannot be selected")
		}
		if err := selector.Set(selected); err != nil {
			runLock.Unlock()
			return err
		}
	}
	for group := range before.Selected {
		if _, exists := payload.Selected[group]; exists {
			continue
		}
		if proxy := proxies[group]; proxy != nil {
			if selector, ok := proxy.Adapter().(outboundgroup.SelectAble); ok {
				selector.ForceSet("")
			}
		}
	}
	runLock.Unlock()
	handleSetState(string(payload.State))
	return ctx.Err()
}
func (backendEngine) Start(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !handleStartListener() {
		return errors.New("listener start failed")
	}
	return nil
}
func (backendEngine) Stop(context.Context) error { handleStopListener(); return nil }
func (backendEngine) Observe(context.Context) (backend.Observation, error) {
	runLock.Lock()
	defer runLock.Unlock()
	if isRunning {
		return backend.Observation{State: "running"}, nil
	}
	return backend.Observation{State: "stopped"}, nil
}

type backendPlatform struct{}

func (backendPlatform) Start(ctx context.Context, plan *backend.RuntimePlan) error {
	return platformBroker.Call(ctx, "vpn.start", map[string]uint64{"generation": plan.Generation()}, nil)
}
func (backendPlatform) Stop(ctx context.Context) error {
	return platformBroker.Call(ctx, "vpn.stop", nil, nil)
}
func (backendPlatform) Observe(ctx context.Context) (backend.Observation, error) {
	var value backend.Observation
	err := platformBroker.Call(ctx, "vpn.observe", nil, &value)
	return value, err
}

type backendInspection struct{}

func (backendEngine) SystemDNS(ctx context.Context, addresses []string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	dns.UpdateSystemDNS(normalizeSystemDNSServersPortable(addresses))
	dns.FlushCacheWithDefaultResolver()
	return ctx.Err()
}
func normalizeSystemDNSServersPortable(addresses []string) []string {
	result := []string{}
	for _, address := range addresses {
		if ip, err := netip.ParseAddr(address); err == nil && ip.Zone() == "" {
			result = append(result, net.JoinHostPort(ip.String(), "53"))
		}
	}
	return result
}
func (e backendEngine) ResetNetwork(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if e.probe != nil {
		e.probe.ClearDNSCache()
	}
	handleResetConnections()
	handleCloseConnections()
	return ctx.Err()
}
func (backendEngine) ScreenActive(ctx context.Context, active bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	handleSetScreenActive(active)
	return ctx.Err()
}
func (backendEngine) Awake(ctx context.Context, active bool) error {
	return platformBroker.Call(ctx, "vpn.awake", map[string]bool{"active": active}, nil)
}
func (backendEngine) ProbeHealth(ctx context.Context) (bool, error) {
	runLock.Lock()
	target := currentTestURL
	proxy := proxiesWithProviders()["GLOBAL"]
	runLock.Unlock()
	if target == "" {
		return true, nil
	}
	if proxy == nil {
		return false, errors.New("no active outbound")
	}
	expected, _ := utils.NewUnsignedRanges[uint16]("")
	delay, err := proxy.URLTest(ctx, target, expected)
	return delay > 0 && err == nil, err
}

func (backendInspection) HasNetwork(ctx context.Context) (bool, error) {
	var value bool
	err := platformBroker.Call(ctx, "network.available", nil, &value)
	return value, err
}
func (backendInspection) NetworkScope(ctx context.Context) (string, error) {
	var value string
	err := platformBroker.Call(ctx, "network.scope", nil, &value)
	return value, err
}
func (backendInspection) Selected(ctx context.Context, names []string) (map[string]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	runLock.Lock()
	defer runLock.Unlock()
	result := map[string]string{}
	proxies := proxiesWithProviders()
	for _, name := range names {
		p := proxies[name]
		if p == nil {
			continue
		}
		data, err := p.MarshalJSON()
		if err != nil {
			return nil, err
		}
		var value struct {
			Now string `json:"now"`
		}
		if err = json.Unmarshal(data, &value); err != nil {
			return nil, err
		}
		if value.Now != "" {
			result[name] = value.Now
		}
	}
	return result, nil
}
func (backendInspection) Connections(ctx context.Context) ([][]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	result := [][]string{}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		result = append(result, append([]string(nil), c.Chains()...))
		return true
	})
	return result, nil
}
func (backendInspection) TestGroup(ctx context.Context, name string, urls []string) (bool, error) {
	runLock.Lock()
	p := proxiesWithProviders()[name]
	runLock.Unlock()
	if p == nil {
		return false, errors.New("unknown proxy group")
	}
	expected, _ := utils.NewUnsignedRanges[uint16]("")
	for _, url := range urls {
		if _, err := p.URLTest(ctx, url, expected); err == nil {
			return true, nil
		}
		if err := ctx.Err(); err != nil {
			return false, err
		}
	}
	return false, nil
}

type backendPackageLists struct{ client *http.Client }

func (l backendPackageLists) Read(ctx context.Context, _, address string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	response, err := l.client.Do(req)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", errors.New("package list download failed")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20+1))
	if err != nil {
		return "", err
	}
	if len(body) > 1<<20 {
		return "", errors.New("package list too large")
	}
	return string(bytes.ToValidUTF8(body, []byte("�"))), nil
}
