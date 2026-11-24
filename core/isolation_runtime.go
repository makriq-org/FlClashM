package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"slices"
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
		// state.CurrentState is decoded in place, so the guard must not share
		// backing arrays with it: a later settings commit could overwrite a list
		// while a TUN thread reads the published policy.
		policy.Access = isolation.Access{
			Enabled:    true,
			AcceptMode: access.Mode == "acceptSelected",
			Accept:     slices.Clone(access.AcceptList),
			Reject:     slices.Clone(access.RejectList),
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

// ownerAnswer is the JSON contract of the Android connection-owner callback.
type ownerAnswer struct {
	UID      int      `json:"uid"`
	Packages []string `json:"packages"`
	Unknown  bool     `json:"unknown"`
	Error    string   `json:"error"`
}

// parseOwnerAnswer turns one callback answer into an owner. Anything that does
// not clearly identify a UID and its package list fails closed as an error, so
// the guard treats it as an unattributable flow instead of priming a decision.
func parseOwnerAnswer(raw string) (isolation.Owner, error) {
	var answer ownerAnswer
	if err := json.Unmarshal([]byte(raw), &answer); err != nil {
		return isolation.Owner{}, fmt.Errorf("connection owner answer: %w", err)
	}
	if answer.Error != "" {
		return isolation.Owner{}, errors.New(answer.Error)
	}
	if answer.Unknown || answer.UID < 0 {
		return isolation.Owner{Known: false}, nil
	}
	// A resolved owner always carries its package list (possibly empty for a
	// system UID). A partial answer would otherwise look like root and pass.
	if answer.Packages == nil {
		return isolation.Owner{}, errors.New("connection owner answer has no package list")
	}
	return isolation.Owner{Known: true, UID: answer.UID, Packages: answer.Packages}, nil
}
