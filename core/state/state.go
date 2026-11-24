package state

import "net/netip"

var DefaultIpv4Address = "172.19.0.1/30"
var DefaultDnsAddress = "172.19.0.2"
var DefaultIpv6Address = "fdfe:dcba:9876::1/126"

// AppIsolationOptions is the effective `tun.app-isolation` plus the host-side
// state of the in-TUN check. Mode and source come from the compiled plan;
// status, detail and capability are filled by the running guard so the UI can
// report a policy it could not apply in full.
type AppIsolationOptions struct {
	Mode       string `json:"mode"`
	Source     string `json:"source"`
	Status     string `json:"status,omitempty"`     // off, applied, limited, unavailable
	Detail     string `json:"detail,omitempty"`     // first actionable reason
	Capability string `json:"capability,omitempty"` // full, procfs, none
}

type AndroidVpnOptions struct {
	Enable           bool                 `json:"enable"`
	Port             int                  `json:"port"`
	AccessControl    *AccessControl       `json:"accessControl"`
	AllowBypass      bool                 `json:"allowBypass"`
	SystemProxy      bool                 `json:"systemProxy"`
	BypassDomain     []string             `json:"bypassDomain"`
	RouteAddress     []netip.Prefix       `json:"routeAddress"`
	Ipv4Address      string               `json:"ipv4Address"`
	Ipv6             bool                 `json:"ipv6"`
	Ipv6Address      string               `json:"ipv6Address"`
	DnsServerAddress string               `json:"dnsServerAddress"`
	IncludePackage   []string             `json:"includePackage"`
	ExcludePackage   []string             `json:"excludePackage"`
	AppIsolation     *AppIsolationOptions `json:"appIsolation,omitempty"`
}

type AccessControl struct {
	Enable     bool     `json:"enable"`
	Mode       string   `json:"mode"`
	AcceptList []string `json:"acceptList"`
	RejectList []string `json:"rejectList"`
}

type AndroidVpnRawOptions struct {
	Enable        bool           `json:"enable"`
	AccessControl *AccessControl `json:"accessControl"`
	AllowBypass   bool           `json:"allowBypass"`
	SystemProxy   bool           `json:"systemProxy"`
	Ipv6          bool           `json:"ipv6"`
}

type State struct {
	VpnProps           AndroidVpnRawOptions `json:"vpn-props"`
	CurrentProfileName string               `json:"current-profile-name"`
	BypassDomain       []string             `json:"bypass-domain"`
	// AppIsolation is the compiled Android-only policy. Older plans omit it,
	// so consumers must reconstruct the balanced default instead of treating a
	// zero value as "off".
	AppIsolation AppIsolationOptions `json:"app-isolation"`
}

var CurrentState = &State{
	CurrentProfileName: "",
}

func GetIpv6Address() string {
	if CurrentState.VpnProps.Ipv6 {
		return DefaultIpv6Address
	} else {
		return ""
	}
}

func GetDnsServerAddress() string {
	return DefaultDnsAddress
}
