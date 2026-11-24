package main

import (
	"net/netip"
	"sync/atomic"

	"core/isolation"
	"core/state"
)

// activeIsolationGuard is the policy installed for the running TUN. It is
// nil while the VPN is down, so stale hooks and restored plans cannot keep
// enforcing a mode the user has left.
var activeIsolationGuard atomic.Pointer[isolation.Guard]

// isolationPolicy reads the mode and app access policy actually applied to the
// Android VPN. Both come from the same compiled core state that drives
// VpnService.Builder, so there is no second allow/deny list to drift. The
// caller holds runLock, like every other reader of CurrentState.
func isolationPolicy() isolation.Policy {
	mode, ok := isolation.ParseMode(state.CurrentState.AppIsolation.Mode)
	if !ok {
		// Plans written before tun.app-isolation existed have no mode.
		mode = isolation.Default
	}
	policy := isolation.Policy{Mode: mode, TunAddr: isolationTunAddresses()}
	if access := state.CurrentState.VpnProps.AccessControl; access != nil && access.Enable {
		policy.Access = isolation.Access{
			Enabled:    true,
			AcceptMode: access.Mode == "acceptSelected",
			Accept:     access.AcceptList,
			Reject:     access.RejectList,
		}
	}
	return policy
}

func isolationTunAddresses() []netip.Addr {
	addresses := make([]netip.Addr, 0, 2)
	if prefix, err := netip.ParsePrefix(state.DefaultIpv4Address); err == nil {
		addresses = append(addresses, prefix.Addr())
	}
	if state.CurrentState.VpnProps.Ipv6 {
		if prefix, err := netip.ParsePrefix(state.DefaultIpv6Address); err == nil {
			addresses = append(addresses, prefix.Addr())
		}
	}
	return addresses
}

// refreshIsolationPolicy applies a newly committed core state to the live TUN
// without waiting for a restart. A mode change also recreates the tunnel, but
// the guard must never run with the previous policy in the meantime.
func refreshIsolationPolicy() {
	if guard := activeIsolationGuard.Load(); guard != nil {
		guard.Update(isolationPolicy())
	}
}

// isolationOptions reports the compiled policy and how the running guard is
// actually applying it. A plan from before the field existed is presented as
// the balanced default instead of an empty mode.
func isolationOptions(capability string) *state.AppIsolationOptions {
	mode := state.CurrentState.AppIsolation.Mode
	if parsed, ok := isolation.ParseMode(mode); ok {
		mode = string(parsed)
	} else {
		mode = string(isolation.Default)
	}
	source := state.CurrentState.AppIsolation.Source
	if source == "" {
		source = "default"
	}
	options := &state.AppIsolationOptions{Mode: mode, Source: source, Capability: capability}
	guard := activeIsolationGuard.Load()
	if guard == nil {
		switch {
		case mode == string(isolation.Off):
			options.Status = "off"
		case capability == "none":
			options.Status = "unavailable"
			options.Detail = "connection owner lookup is unavailable"
		default:
			options.Status = "inactive"
		}
		return options
	}
	stats := guard.Stats()
	options.Capability = stats.Capability
	switch {
	case stats.Mode == isolation.Off:
		options.Status = "off"
	case stats.Capability == "none":
		options.Status = "unavailable"
		options.Detail = "connection owner lookup is unavailable"
	case stats.Failures > 0:
		options.Status = "degraded"
		options.Detail = stats.LastError
	case stats.Capability == "procfs":
		options.Status = "limited"
		options.Detail = "owner lookup uses /proc/net on this Android version"
	default:
		options.Status = "applied"
	}
	return options
}
