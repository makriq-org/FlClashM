// Package isolation enforces the Android VPN's app access policy a second time,
// inside the TUN reader. It is engine-independent so the policy can be tested
// without Android or mihomo.
package isolation

import (
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Mode is the compiled tun.app-isolation value.
type Mode string

const (
	// Off keeps only Android's own VpnService routing policy.
	Off Mode = "off"
	// Balanced rejects known disallowed apps and unattributable TCP from the
	// tunnel's own addresses, while leaving UDP, ICMP and forwarded clients.
	Balanced Mode = "balanced"
	// Strict also rejects every unattributable flow, whatever protocol or
	// source address it uses.
	Strict Mode = "strict"
)

// Default is the compatibility mode used when neither the profile nor the user
// asks for one.
const Default = Balanced

func ParseMode(value string) (Mode, bool) {
	mode := Mode(strings.ToLower(strings.TrimSpace(value)))
	switch mode {
	case Off, Balanced, Strict:
		return mode, true
	}
	return "", false
}

// udpCacheTTL bounds a cached UDP attribution. A UDP socket has no connection
// teardown event to evict its entry, so the lifetime keeps a reusable 5-tuple
// from inheriting another app's decision indefinitely.
const udpCacheTTL = 10 * time.Second

const maxUDPCacheEntries = 4096

// Owner distinguishes a resolved socket owner from a flow Android cannot
// attribute. Known owners carry the UID and every package that shares it.
type Owner struct {
	Known    bool
	UID      int
	Packages []string
}

// Resolver attributes one TUN flow. protocol is "tcp" or "udp"; ICMP has no
// per-socket Android API and is never resolved.
type Resolver interface {
	Resolve(protocol string, source, destination netip.AddrPort) (Owner, error)
}

// Access is the VpnService policy actually applied to the running tunnel.
type Access struct {
	Enabled    bool
	AcceptMode bool
	Accept     []string
	Reject     []string
}

// Permits applies the policy to every package sharing the owner's UID.
func (a Access) Permits(owner Owner) bool {
	if !a.Enabled {
		return true
	}
	if a.AcceptMode {
		for _, name := range owner.Packages {
			if contains(a.Accept, name) {
				return true
			}
		}
		return false
	}
	for _, name := range owner.Packages {
		if contains(a.Reject, name) {
			return false
		}
	}
	return true
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

// Policy is one immutable enforcement snapshot.
type Policy struct {
	Mode    Mode
	Access  Access
	TunAddr []netip.Addr
}

// systemExempt lists Android services whose traffic must survive both the app
// policy and the unattributable-owner check. Each entry is needed by the OS:
// root-owned netd sockets, system_server connectivity, telephony/IMS calls,
// Bluetooth and Wi-Fi tethering, the VPN framework, mDNS discovery, the two DNS
// daemons, and NetworkStack validation. Services that never originate tunnel
// traffic (logd, GPS, credstore, shell, nobody) are not exempt: dropping them
// weakens nothing but would hide real misroutes.
var systemExempt = map[int]bool{
	0:    true, // AID_ROOT: netd/kernel-assisted sockets on behalf of apps
	1000: true, // AID_SYSTEM: system_server, SystemUI
	1001: true, // AID_RADIO: telephony, IMS/VoLTE calls
	1002: true, // AID_BLUETOOTH: Bluetooth tethering
	1010: true, // AID_WIFI: Wi-Fi hotspot subsystem
	1016: true, // AID_VPN: Android VPN framework and tethering
	1020: true, // AID_MDNSR: multicast DNS service discovery
	1051: true, // AID_DNS: netd DNS resolution
	1052: true, // AID_DNS_TETHER: dnsmasq for hotspot clients
	1073: true, // AID_NETWORK_STACK: connectivity validation
}

// Stats reports how the applied policy has behaved, for user-visible
// diagnostics.
type Stats struct {
	Mode       Mode
	Failures   uint64
	Denied     uint64
	LastError  string
	Capability string
}

type key struct {
	protocol string
	source   netip.AddrPort
	dest     netip.AddrPort
}

type entry struct {
	allow   bool
	expires time.Time
	// generation fences a decision computed under a policy that has since
	// been replaced: Update clears the map, but a concurrent UDP check could
	// insert an old decision right after that clear.
	generation uint64
}

// Guard applies one policy to TUN flows. Safe for concurrent use.
type Guard struct {
	resolver Resolver
	now      func() time.Time

	policy     atomic.Pointer[Policy]
	generation atomic.Uint64

	mu    sync.Mutex
	cache map[key]entry

	denied   atomic.Uint64
	failures atomic.Uint64
	lastErr  atomic.Pointer[string]

	capability atomic.Pointer[string]
}

func NewGuard(policy Policy, resolver Resolver) *Guard {
	g := &Guard{resolver: resolver, now: time.Now, cache: map[key]entry{}}
	g.policy.Store(&policy)
	g.SetCapability("full")
	return g
}

// SetNow is a test hook for the UDP decision cache.
func (g *Guard) SetNow(now func() time.Time) { g.now = now }

// SetCapability records the host's ownership-resolution quality ("full" on
// API 29+, "procfs" on older releases).
func (g *Guard) SetCapability(value string) {
	value = strings.TrimSpace(value)
	if value == "" {
		value = "full"
	}
	g.capability.Store(&value)
}

// Update replaces the policy and drops every cached decision, so a settings or
// profile change takes effect for the next packet.
func (g *Guard) Update(policy Policy) {
	g.generation.Add(1)
	g.policy.Store(&policy)
	g.mu.Lock()
	g.cache = map[key]entry{}
	g.mu.Unlock()
}

// Check reports whether a flow arriving on the TUN may use the tunnel. It runs
// before DNS hijack and routing, so it must not perform work proportional to
// packet size.
func (g *Guard) Check(protocol string, source, destination netip.AddrPort) bool {
	p := g.policy.Load()
	if p == nil || p.Mode == Off {
		return true
	}
	allow := g.decide(p, protocol, source, destination)
	if !allow {
		g.denied.Add(1)
	}
	return allow
}

func (g *Guard) decide(p *Policy, protocol string, source, destination netip.AddrPort) bool {
	switch protocol {
	case "tcp":
		// A new connection is resolved once. Reusing a port must not inherit
		// the previous owner's decision, so TCP is never cached.
		return g.flowAllowed(p, protocol, source, destination)
	case "udp":
		now := g.now()
		generation := g.generation.Load()
		k := key{protocol, source, destination}
		g.mu.Lock()
		cached, ok := g.cache[k]
		g.mu.Unlock()
		if ok && cached.generation == generation && now.Before(cached.expires) {
			return cached.allow
		}
		allow := g.flowAllowed(p, protocol, source, destination)
		g.mu.Lock()
		if len(g.cache) >= maxUDPCacheEntries {
			g.cache = map[key]entry{}
		}
		g.cache[k] = entry{allow: allow, expires: now.Add(udpCacheTTL), generation: generation}
		g.mu.Unlock()
		return allow
	}
	// ICMP echo cannot be attributed to a socket on any supported API level.
	if p.Mode == Strict {
		return false
	}
	return true
}

func (g *Guard) flowAllowed(p *Policy, protocol string, source, destination netip.AddrPort) bool {
	owner, known := g.owner(protocol, source, destination)
	if known && owner.Known {
		if systemExempt[owner.UID] {
			return true
		}
		return p.Access.Permits(owner)
	}
	if p.Mode == Strict {
		return false
	}
	// Balanced: only TCP injected from the tunnel's own addresses is dropped.
	// Forwarded hotspot clients have foreign source addresses; UDP stays
	// permissive for calls and sharing.
	return !(protocol == "tcp" && p.ownsTunAddress(source.Addr()))
}

func (p *Policy) ownsTunAddress(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, own := range p.TunAddr {
		if own.Unmap() == addr {
			return true
		}
	}
	return false
}

func (g *Guard) owner(protocol string, source, destination netip.AddrPort) (Owner, bool) {
	if g.resolver == nil {
		return Owner{}, false
	}
	owner, err := g.resolver.Resolve(protocol, source, destination)
	if err != nil {
		g.fail(err)
		return Owner{}, false
	}
	return owner, true
}

func (g *Guard) fail(err error) {
	if err == nil {
		return
	}
	g.failures.Add(1)
	message := err.Error()
	g.lastErr.Store(&message)
}

// Stats is a point-in-time diagnostic snapshot.
func (g *Guard) Stats() Stats {
	stats := Stats{Denied: g.denied.Load(), Failures: g.failures.Load()}
	if p := g.policy.Load(); p != nil {
		stats.Mode = p.Mode
	}
	if message := g.lastErr.Load(); message != nil {
		stats.LastError = *message
	}
	if capability := g.capability.Load(); capability != nil {
		stats.Capability = *capability
	}
	return stats
}
