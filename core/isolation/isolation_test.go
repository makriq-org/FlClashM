package isolation

import (
	"errors"
	"net/netip"
	"sync"
	"testing"
	"time"
)

type fakeResolver struct {
	mu     sync.Mutex
	owners map[string]Owner
	errs   map[string]error
	calls  map[string]int
}

func (f *fakeResolver) Resolve(protocol string, source, destination netip.AddrPort) (Owner, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.calls == nil {
		f.calls = map[string]int{}
	}
	key := protocol + " " + source.String() + " " + destination.String()
	f.calls[key]++
	if err := f.errs[key]; err != nil {
		return Owner{}, err
	}
	owner, ok := f.owners[key]
	if !ok {
		return Owner{}, nil
	}
	return owner, nil
}

func (f *fakeResolver) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[key]
}

var (
	tunV4   = netip.MustParseAddr("172.19.0.1")
	tunV6   = netip.MustParseAddr("fdfe:dcba:9876::1")
	hotspot = netip.MustParseAddr("192.168.43.7")
	remote  = netip.MustParseAddrPort("1.1.1.1:443")
)

func tunPolicy(mode Mode, access Access) Policy {
	return Policy{Mode: mode, Access: access, TunAddr: []netip.Addr{tunV4, tunV6}}
}

func TestOffAllowsEverything(t *testing.T) {
	guard := NewGuard(tunPolicy(Off, Access{Enabled: true, AcceptMode: true}), &fakeResolver{})
	if !guard.Check("tcp", netip.MustParseAddrPort("172.19.0.1:1234"), remote) {
		t.Fatal("off mode denied a flow")
	}
}

func TestBalancedKnownOwnerPolicy(t *testing.T) {
	resolver := &fakeResolver{owners: map[string]Owner{
		"tcp 172.19.0.1:1234 1.1.1.1:443": {Known: true, UID: 10123, Packages: []string{"com.allowed"}},
		"tcp 172.19.0.1:1235 1.1.1.1:443": {Known: true, UID: 10124, Packages: []string{"com.blocked"}},
		"tcp 172.19.0.1:1236 1.1.1.1:443": {Known: true, UID: 10125, Packages: []string{"com.ok", "com.blocked"}},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true, Reject: []string{"com.blocked"}}), resolver)
	src := func(port int) netip.AddrPort { return netip.AddrPortFrom(tunV4, uint16(port)) }
	if !guard.Check("tcp", src(1234), remote) {
		t.Fatal("allowed app was denied")
	}
	if guard.Check("tcp", src(1235), remote) {
		t.Fatal("rejected app was allowed")
	}
	if guard.Check("tcp", src(1236), remote) {
		t.Fatal("a shared UID with one rejected package was allowed")
	}
	if guard.Stats().Denied != 2 {
		t.Fatalf("denied counter = %d, want 2", guard.Stats().Denied)
	}
}

func TestAcceptModeRequiresListedPackage(t *testing.T) {
	resolver := &fakeResolver{owners: map[string]Owner{
		"tcp 172.19.0.1:1234 1.1.1.1:443": {Known: true, UID: 10123, Packages: []string{"com.allowed"}},
		"tcp 172.19.0.1:1235 1.1.1.1:443": {Known: true, UID: 10124, Packages: []string{"com.other"}},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true, AcceptMode: true, Accept: []string{"com.allowed"}}), resolver)
	src := func(port int) netip.AddrPort { return netip.AddrPortFrom(tunV4, uint16(port)) }
	if !guard.Check("tcp", src(1234), remote) {
		t.Fatal("listed app was denied")
	}
	if guard.Check("tcp", src(1235), remote) {
		t.Fatal("unlisted app was allowed in accept mode")
	}
}

func TestBalancedUnknownOwners(t *testing.T) {
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true}), &fakeResolver{})
	fromTun := netip.AddrPortFrom(tunV4, 5555)
	fromTun6 := netip.AddrPortFrom(tunV6, 5555)
	fromClient := netip.AddrPortFrom(hotspot, 5555)
	if guard.Check("tcp", fromTun, remote) {
		t.Fatal("unattributable TCP from the tunnel address was allowed")
	}
	if guard.Check("tcp", fromTun6, remote) {
		t.Fatal("unattributable TCP from the IPv6 tunnel address was allowed")
	}
	if !guard.Check("tcp", fromClient, remote) {
		t.Fatal("forwarded client TCP was denied in balanced mode")
	}
	if !guard.Check("udp", fromTun, remote) {
		t.Fatal("UDP was denied in balanced mode")
	}
	if !guard.Check("icmp", fromTun, remote) {
		t.Fatal("ICMP was denied in balanced mode")
	}
}

func TestStrictUnknownOwnersEverywhere(t *testing.T) {
	guard := NewGuard(tunPolicy(Strict, Access{Enabled: true}), &fakeResolver{})
	for _, protocol := range []string{"tcp", "udp", "icmp"} {
		for _, source := range []netip.AddrPort{
			netip.AddrPortFrom(tunV4, 5555),
			netip.AddrPortFrom(hotspot, 5555),
			remote,
		} {
			if guard.Check(protocol, source, remote) {
				t.Fatalf("strict allowed unattributable %s from %s", protocol, source)
			}
		}
	}
}

func TestSystemServicesSurviveBothModes(t *testing.T) {
	resolver := &fakeResolver{owners: map[string]Owner{
		"tcp 172.19.0.1:1234 1.1.1.1:443": {Known: true, UID: 1052, Packages: []string{"android"}},
		"tcp 172.19.0.1:1235 1.1.1.1:443": {Known: true, UID: 1029},
	}}
	guard := NewGuard(tunPolicy(Strict, Access{Enabled: true, AcceptMode: true, Accept: []string{"com.allowed"}}), resolver)
	src := func(port int) netip.AddrPort { return netip.AddrPortFrom(tunV4, uint16(port)) }
	if !guard.Check("tcp", src(1234), remote) {
		t.Fatal("the DNS daemon was denied")
	}
	if guard.Check("tcp", src(1235), remote) {
		t.Fatal("an unlisted system UID was allowed in accept mode")
	}
}

func TestResolverErrorsFailClosedForUnknownChecks(t *testing.T) {
	key := "tcp 172.19.0.1:1234 1.1.1.1:443"
	resolver := &fakeResolver{errs: map[string]error{key: errors.New("SecurityException")}}
	guard := NewGuard(tunPolicy(Strict, Access{Enabled: true}), resolver)
	if guard.Check("tcp", netip.MustParseAddrPort("172.19.0.1:1234"), remote) {
		t.Fatal("a failed lookup was allowed in strict mode")
	}
	stats := guard.Stats()
	if stats.Failures != 1 || stats.LastError != "SecurityException" {
		t.Fatalf("stats = %#v", stats)
	}
}

func TestUDPDecisionCacheLifecycle(t *testing.T) {
	source := netip.MustParseAddrPort("172.19.0.1:5300")
	key := "udp " + source.String() + " " + remote.String()
	resolver := &fakeResolver{owners: map[string]Owner{
		key: {Known: true, UID: 10123, Packages: []string{"com.blocked"}},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true, Reject: []string{"com.blocked"}}), resolver)
	now := time.Unix(100, 0)
	guard.SetNow(func() time.Time { return now })
	for range 3 {
		if guard.Check("udp", source, remote) {
			t.Fatal("cached rejection was lost")
		}
	}
	if calls := resolver.count(key); calls != 1 {
		t.Fatalf("resolver calls = %d, want 1", calls)
	}
	now = now.Add(udpCacheTTL + time.Second)
	if guard.Check("udp", source, remote) {
		t.Fatal("expired entry kept the rejection")
	}
	if calls := resolver.count(key); calls != 2 {
		t.Fatalf("resolver calls = %d, want 2", calls)
	}
	guard.Update(tunPolicy(Balanced, Access{Enabled: true}))
	if !guard.Check("udp", source, remote) {
		t.Fatal("policy update reused the expired decision")
	}
	if calls := resolver.count(key); calls != 3 {
		t.Fatalf("resolver calls = %d, want 3", calls)
	}
}

func TestTCPIsNeverCached(t *testing.T) {
	source := netip.MustParseAddrPort("172.19.0.1:5300")
	key := "tcp " + source.String() + " " + remote.String()
	resolver := &fakeResolver{owners: map[string]Owner{
		key: {Known: true, UID: 10123, Packages: []string{"com.allowed"}},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true}), resolver)
	guard.Check("tcp", source, remote)
	guard.Check("tcp", source, remote)
	if calls := resolver.count(key); calls != 2 {
		t.Fatalf("resolver calls = %d, want 2", calls)
	}
}

func TestPolicyUpdateInvalidatesAnInFlightUDPDecision(t *testing.T) {
	source := netip.MustParseAddrPort("172.19.0.1:5300")
	cacheKey := "udp " + source.String() + " " + remote.String()
	resolver := &fakeResolver{owners: map[string]Owner{
		cacheKey: {Known: true, UID: 10123, Packages: []string{"com.allowed"}},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true}), resolver)
	oldGeneration := guard.current.Load().generation
	guard.Update(tunPolicy(Balanced, Access{Enabled: true, Reject: []string{"com.allowed"}}))
	// A check that started before the update may insert its decision after the
	// cache was cleared; the generation must keep that entry inert.
	guard.mu.Lock()
	guard.cache[key{protocol: "udp", source: source, dest: remote}] = entry{
		allow:      true,
		expires:    time.Now().Add(time.Minute),
		generation: oldGeneration,
	}
	guard.mu.Unlock()
	if guard.Check("udp", source, remote) {
		t.Fatal("an old-generation allow survived the policy update")
	}
}

func TestQUICFlowsFollowTheUDPPolicy(t *testing.T) {
	source := netip.MustParseAddrPort("172.19.0.1:5555")
	quic := netip.MustParseAddrPort("203.0.113.9:443")
	// An unattributable QUIC flow is UDP: balanced keeps it for calls/sharing,
	// strict rejects it like any other unknown UDP flow.
	if !NewGuard(tunPolicy(Balanced, Access{Enabled: true}), &fakeResolver{}).Check("udp", source, quic) {
		t.Fatal("balanced denied unattributable QUIC")
	}
	if NewGuard(tunPolicy(Strict, Access{Enabled: true}), &fakeResolver{}).Check("udp", source, quic) {
		t.Fatal("strict allowed unattributable QUIC")
	}
	// A known excluded app is denied for QUIC through the same access policy.
	resolver := &fakeResolver{owners: map[string]Owner{
		"udp " + source.String() + " " + quic.String(): {
			Known: true, UID: 10123, Packages: []string{"com.example.blocked"},
		},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true, Reject: []string{"com.example.blocked"}}), resolver)
	if guard.Check("udp", source, quic) {
		t.Fatal("balanced allowed excluded app QUIC")
	}
}

func TestDNSPacketsUseTheUDPPolicy(t *testing.T) {
	source := netip.MustParseAddrPort("172.19.0.1:5353")
	dns := netip.MustParseAddrPort("172.19.0.2:53")
	if !NewGuard(tunPolicy(Balanced, Access{Enabled: true}), &fakeResolver{}).Check("udp", source, dns) {
		t.Fatal("balanced denied unattributable DNS")
	}
	if NewGuard(tunPolicy(Strict, Access{Enabled: true}), &fakeResolver{}).Check("udp", source, dns) {
		t.Fatal("strict allowed unattributable DNS")
	}
	// netd's resolver is a system service and must survive strict mode.
	resolver := &fakeResolver{owners: map[string]Owner{
		"udp " + source.String() + " " + dns.String(): {Known: true, UID: 1051},
	}}
	if !NewGuard(tunPolicy(Strict, Access{Enabled: true}), resolver).Check("udp", source, dns) {
		t.Fatal("strict denied the system DNS resolver")
	}
}

func TestSharedUIDInAcceptModeNeedsAnyListedPackage(t *testing.T) {
	source := netip.MustParseAddrPort("172.19.0.1:4100")
	resolver := &fakeResolver{owners: map[string]Owner{
		"tcp " + source.String() + " " + remote.String(): {
			Known: true, UID: 10124, Packages: []string{"com.not.listed", "com.allowed"},
		},
	}}
	guard := NewGuard(tunPolicy(Balanced, Access{
		Enabled: true, AcceptMode: true, Accept: []string{"com.allowed"},
	}), resolver)
	if !guard.Check("tcp", source, remote) {
		t.Fatal("shared UID with one accepted package was denied")
	}
}

func TestTransientFailureDoesNotStayDegraded(t *testing.T) {
	key := "tcp 172.19.0.1:1234 1.1.1.1:443"
	resolver := &fakeResolver{
		owners: map[string]Owner{key: {Known: true, UID: 10123, Packages: []string{"com.allowed"}}},
		errs:   map[string]error{key: errors.New("SecurityException")},
	}
	guard := NewGuard(tunPolicy(Balanced, Access{Enabled: true}), resolver)
	source := netip.MustParseAddrPort("172.19.0.1:1234")
	if guard.Check("tcp", source, remote) {
		t.Fatal("a failed lookup was allowed from the tunnel address")
	}
	if stats := guard.Stats(); stats.Failures != 1 {
		t.Fatalf("first failure was not recorded: %#v", stats)
	}
	// The first flow was resolved with an error; a later success clears it.
	resolver.mu.Lock()
	delete(resolver.errs, key)
	resolver.mu.Unlock()
	if !guard.Check("tcp", source, remote) {
		t.Fatal("known owner denied after the lookup recovered")
	}
	if stats := guard.Stats(); stats.Failures != 0 || stats.LastError != "" {
		t.Fatalf("stats = %#v", stats)
	}
}
