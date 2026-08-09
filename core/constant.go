package main

import (
	"encoding/json"
	"net/http"
	"net/netip"
	"time"

	"github.com/metacubex/mihomo/adapter/provider"
	P "github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type InitParams struct {
	HomeDir string `json:"home-dir"`
	Version int    `json:"version"`
}

type SetupParams struct {
	Config      *config.RawConfig `json:"config"`
	SelectedMap map[string]string `json:"selected-map"`
	TestURL     string            `json:"test-url"`
}

type UpdateParams struct {
	Tun                *tunSchema         `json:"tun"`
	AllowLan           *bool              `json:"allow-lan"`
	MixedPort          *int               `json:"mixed-port"`
	FindProcessMode    *P.FindProcessMode `json:"find-process-mode"`
	Mode               *tunnel.TunnelMode `json:"mode"`
	LogLevel           *log.LogLevel      `json:"log-level"`
	IPv6               *bool              `json:"ipv6"`
	Sniffing           *bool              `json:"sniffing"`
	TCPConcurrent      *bool              `json:"tcp-concurrent"`
	ExternalController *string            `json:"external-controller"`
	Interface          *string            `json:"interface-name"`
	UnifiedDelay       *bool              `json:"unified-delay"`
}

// TunnelHTTPRequest is an internal control-plane request. It deliberately has
// no proxy address: the request always enters mihomo through tunnel.Tunnel and
// is then routed by the active profile just like any other connection.
type TunnelHTTPRequest struct {
	URL            string            `json:"url"`
	Method         string            `json:"method"`
	Headers        map[string]string `json:"headers"`
	Body           string            `json:"body"`
	TimeoutMillis  int64             `json:"timeout-millis"`
	MaxResponseLen int64             `json:"max-response-len"`
	TargetPath     string            `json:"target-path"`
	RequestID      string            `json:"request-id"`
}

type TunnelHTTPResponse struct {
	StatusCode int         `json:"status-code"`
	Headers    http.Header `json:"headers"`
	Body       []byte      `json:"body"`
	FinalURL   string      `json:"final-url"`
	WrittenLen int64       `json:"written-len"`
	Error      string      `json:"error,omitempty"`
}

type RuntimeSnapshot struct {
	Config    map[string]any `json:"config"`
	Listeners any            `json:"listeners"`
	Running   bool           `json:"running"`
	TunUp     bool           `json:"tun-up"`
}

type tunSchema struct {
	Enable       bool               `yaml:"enable" json:"enable"`
	Device       *string            `yaml:"device" json:"device"`
	Stack        *constant.TUNStack `yaml:"stack" json:"stack"`
	DNSHijack    *[]string          `yaml:"dns-hijack" json:"dns-hijack"`
	AutoRoute    *bool              `yaml:"auto-route" json:"auto-route"`
	RouteAddress *[]netip.Prefix    `yaml:"route-address" json:"route-address,omitempty"`
}

type ChangeProxyParams struct {
	GroupName *string `json:"group-name"`
	ProxyName *string `json:"proxy-name"`
}

type TestDelayParams struct {
	ProxyName string `json:"proxy-name"`
	TestUrl   string `json:"test-url"`
	Timeout   int64  `json:"timeout"`
}

type ExternalProvider struct {
	Name             string                     `json:"name"`
	Type             string                     `json:"type"`
	VehicleType      string                     `json:"vehicle-type"`
	Count            int                        `json:"count"`
	Path             string                     `json:"path"`
	UpdateAt         time.Time                  `json:"update-at"`
	SubscriptionInfo *provider.SubscriptionInfo `json:"subscription-info"`
}

const (
	messageMethod                  Method = "message"
	initClashMethod                Method = "initClash"
	getIsInitMethod                Method = "getIsInit"
	forceGcMethod                  Method = "forceGc"
	shutdownMethod                 Method = "shutdown"
	validateConfigMethod           Method = "validateConfig"
	updateConfigMethod             Method = "updateConfig"
	getProxiesMethod               Method = "getProxies"
	changeProxyMethod              Method = "changeProxy"
	getTrafficMethod               Method = "getTraffic"
	getTotalTrafficMethod          Method = "getTotalTraffic"
	resetTrafficMethod             Method = "resetTraffic"
	asyncTestDelayMethod           Method = "asyncTestDelay"
	getConnectionsMethod           Method = "getConnections"
	closeConnectionsMethod         Method = "closeConnections"
	resetConnectionsMethod         Method = "resetConnections"
	closeConnectionMethod          Method = "closeConnection"
	getExternalProvidersMethod     Method = "getExternalProviders"
	getExternalProviderMethod      Method = "getExternalProvider"
	getCountryCodeMethod           Method = "getCountryCode"
	getMemoryMethod                Method = "getMemory"
	updateGeoDataMethod            Method = "updateGeoData"
	updateExternalProviderMethod   Method = "updateExternalProvider"
	sideLoadExternalProviderMethod Method = "sideLoadExternalProvider"
	startLogMethod                 Method = "startLog"
	stopLogMethod                  Method = "stopLog"
	startListenerMethod            Method = "startListener"
	stopListenerMethod             Method = "stopListener"
	updateDnsMethod                Method = "updateDns"
	setStateMethod                 Method = "setState"
	getAndroidVpnOptionsMethod     Method = "getAndroidVpnOptions"
	getRunTimeMethod               Method = "getRunTime"
	getCurrentProfileNameMethod    Method = "getCurrentProfileName"
	crashMethod                    Method = "crash"
	setupConfigMethod              Method = "setupConfig"
	getConfigMethod                Method = "getConfig"
	getCoreVersionMethod           Method = "getCoreVersion"
	healthCheckMethod              Method = "healthCheck"
	healthProbeMethod              Method = "healthProbe"
	setUiActiveMethod              Method = "setUiActive"
	setScreenActiveMethod          Method = "setScreenActive"
	tunnelHTTPRequestMethod        Method = "tunnelHTTPRequest"
	getRuntimeSnapshotMethod       Method = "getRuntimeSnapshot"
	cancelTunnelHTTPRequestMethod  Method = "cancelTunnelHTTPRequest"
)

type Method string

type MessageType string

type Delay struct {
	Url   string `json:"url"`
	Name  string `json:"name"`
	Value int32  `json:"value"`
}

type Message struct {
	Type MessageType `json:"type"`
	Data interface{} `json:"data"`
}

const (
	LogMessage     MessageType = "log"
	DelayMessage   MessageType = "delay"
	RequestMessage MessageType = "request"
	LoadedMessage  MessageType = "loaded"
)

func (message *Message) Json() (string, error) {
	data, err := json.Marshal(message)
	return string(data), err
}
