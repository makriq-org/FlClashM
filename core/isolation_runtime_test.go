package main

import (
	"errors"
	"net/netip"
	"testing"

	"core/isolation"
	"core/state"
)

type failingResolver struct{}

func (failingResolver) Resolve(string, netip.AddrPort, netip.AddrPort) (isolation.Owner, error) {
	return isolation.Owner{}, errors.New("SecurityException")
}

func withState(t *testing.T, app state.AppIsolationOptions, access *state.AccessControl) {
	t.Helper()
	previous := *state.CurrentState
	previousGuard := activeIsolationGuard.Load()
	t.Cleanup(func() {
		*state.CurrentState = previous
		activeIsolationGuard.Store(previousGuard)
	})
	state.CurrentState.AppIsolation = app
	state.CurrentState.VpnProps.AccessControl = access
	activeIsolationGuard.Store(nil)
}

func TestIsolationPolicyReconstructsLegacyDefaults(t *testing.T) {
	withState(t, state.AppIsolationOptions{}, &state.AccessControl{Enable: true, Mode: "rejectSelected", RejectList: []string{"com.example.blocked"}})
	policy := isolationPolicy()
	if policy.Mode != isolation.Default {
		t.Fatalf("mode = %q, want %q", policy.Mode, isolation.Default)
	}
	if !policy.Access.Enabled || policy.Access.AcceptMode || len(policy.Access.Reject) != 1 {
		t.Fatalf("access = %#v", policy.Access)
	}
	if len(policy.TunAddr) != 1 || policy.TunAddr[0] != netip.MustParseAddr("172.19.0.1") {
		t.Fatalf("tun addresses = %v", policy.TunAddr)
	}
	state.CurrentState.VpnProps.Ipv6 = true
	if addresses := isolationPolicy().TunAddr; len(addresses) != 2 {
		t.Fatalf("ipv6 tunnel address missing: %v", addresses)
	}
}

func TestIsolationOptionsStates(t *testing.T) {
	cases := []struct {
		name       string
		mode       string
		guard      *isolation.Guard
		capability string
		status     string
		detail     string
	}{
		{"inactive", "balanced", nil, "full", "inactive", ""},
		{"unavailable without a guard", "balanced", nil, "none", "unavailable", ""},
		{"off without guard", "off", nil, "full", "off", ""},
		{"applied", "strict", isolation.NewGuard(isolation.Policy{Mode: isolation.Strict}, nil), "full", "applied", ""},
		{"off guard", "balanced", isolation.NewGuard(isolation.Policy{Mode: isolation.Off}, nil), "full", "off", ""},
		{"procfs", "balanced", isolation.NewGuard(isolation.Policy{Mode: isolation.Balanced}, nil), "procfs", "limited", ""},
		{"none", "balanced", isolation.NewGuard(isolation.Policy{Mode: isolation.Balanced}, nil), "none", "unavailable", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withState(t, state.AppIsolationOptions{Mode: tc.mode, Source: "user"}, nil)
			activeIsolationGuard.Store(tc.guard)
			if tc.guard != nil {
				tc.guard.SetCapability(tc.capability)
			}
			options := isolationOptions(tc.capability)
			if options.Status != tc.status {
				t.Fatalf("status = %q, want %q (%#v)", options.Status, tc.status, options)
			}
			if tc.mode == "off" && options.Mode != "off" {
				t.Fatalf("mode = %q, want off", options.Mode)
			}
		})
	}
}

func TestIsolationOptionsReconstructsAnInvalidStoredMode(t *testing.T) {
	withState(t, state.AppIsolationOptions{Mode: "sometimes"}, nil)
	options := isolationOptions("full")
	if options.Mode != "balanced" || options.Source != "default" {
		t.Fatalf("options = %#v", options)
	}
}

func TestIsolationOptionsReportsResolverFailures(t *testing.T) {
	withState(t, state.AppIsolationOptions{Mode: "strict", Source: "profile"}, nil)
	guard := isolation.NewGuard(isolation.Policy{Mode: isolation.Strict}, failingResolver{})
	guard.SetCapability("full")
	activeIsolationGuard.Store(guard)
	guard.Check("tcp", netip.MustParseAddrPort("172.19.0.1:1000"), netip.MustParseAddrPort("1.1.1.1:443"))
	options := isolationOptions("full")
	if options.Status != "degraded" || options.Detail != "SecurityException" {
		t.Fatalf("options = %#v", options)
	}
}

func TestRefreshIsolationPolicyClearsTheGuardWhenStateChanges(t *testing.T) {
	withState(t, state.AppIsolationOptions{Mode: "balanced"}, nil)
	guard := isolation.NewGuard(isolation.Policy{Mode: isolation.Balanced}, nil)
	activeIsolationGuard.Store(guard)
	state.CurrentState.AppIsolation.Mode = "strict"
	refreshIsolationPolicy()
	if guard.Stats().Mode != isolation.Strict {
		t.Fatalf("guard mode = %q", guard.Stats().Mode)
	}
}

func TestParseOwnerAnswer(t *testing.T) {
	owner, err := parseOwnerAnswer(`{"uid":10123,"packages":["com.example.one","com.example.two"]}`)
	if err != nil || !owner.Known || owner.UID != 10123 || len(owner.Packages) != 2 {
		t.Fatalf("owner = %#v, err = %v", owner, err)
	}
	owner, err = parseOwnerAnswer(`{"uid":1051,"packages":[]}`)
	if err != nil || !owner.Known || owner.UID != 1051 || owner.Packages == nil {
		t.Fatalf("system owner = %#v, err = %v", owner, err)
	}
	owner, err = parseOwnerAnswer(`{"unknown":true}`)
	if err != nil || owner.Known {
		t.Fatalf("unknown = %#v, err = %v", owner, err)
	}
	if _, err = parseOwnerAnswer(`{"error":"SecurityException"}`); err == nil || err.Error() != "SecurityException" {
		t.Fatalf("error answer = %v", err)
	}
	if _, err = parseOwnerAnswer(`not json`); err == nil {
		t.Fatal("malformed answer was accepted")
	}
	// A resolved UID without a package list is a protocol violation; treating it
	// as known root would let the flow pass.
	if _, err = parseOwnerAnswer(`{"uid":0}`); err == nil {
		t.Fatal("answer without a package list was accepted")
	}
	// A missing or null uid must not collapse into UID 0 and its exemption.
	for _, answer := range []string{`{"packages":[]}`, `{"uid":null,"packages":[]}`} {
		if _, err = parseOwnerAnswer(answer); err == nil {
			t.Fatalf("answer %s without a uid was accepted", answer)
		}
	}
	owner, err = parseOwnerAnswer(`{"uid":0,"packages":[]}`)
	if err != nil || !owner.Known || owner.UID != 0 {
		t.Fatalf("explicit root = %#v, err = %v", owner, err)
	}
}

func TestMalformedStateKeepsTheActiveAccessPolicy(t *testing.T) {
	withState(t, state.AppIsolationOptions{Mode: "strict"}, &state.AccessControl{
		Enable:     true,
		Mode:       "rejectSelected",
		RejectList: []string{"com.example.blocked"},
	})
	guard := isolation.NewGuard(isolationPolicy(), nil)
	activeIsolationGuard.Store(guard)

	// This payload would first disable access control and then fail on the
	// non-string isolation mode.
	handleSetState(`{"vpn-props":{"accessControl":{"enable":false}},"app-isolation":{"mode":123}}`)

	policy := isolationPolicy()
	if !policy.Access.Enabled || len(policy.Access.Reject) != 1 {
		t.Fatalf("access policy was weakened: %#v", policy.Access)
	}
	if policy.Mode != isolation.Strict {
		t.Fatalf("mode = %q", policy.Mode)
	}
	if guard.Stats().Mode != isolation.Strict {
		t.Fatalf("guard mode = %q", guard.Stats().Mode)
	}
}
