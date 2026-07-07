//go:build android && cgo

package tun

import "C"
import (
	"core/state"
	"fmt"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"net"
	"net/netip"
)

type Props struct {
	Fd       int    `json:"fd"`
	Gateway  string `json:"gateway"`
	Gateway6 string `json:"gateway6"`
	Portal   string `json:"portal"`
	Portal6  string `json:"portal6"`
	Dns      string `json:"dns"`
	Dns6     string `json:"dns6"`
}

func Start(fd int, cfg LC.Tun) (listener *sing_tun.Listener, err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Errorln("startTUN panic recovered: %v", r)
			listener = nil
			err = fmt.Errorf("tun init panic: %v", r)
		}
	}()
	var prefix4 []netip.Prefix
	tempPrefix4, err := netip.ParsePrefix(state.DefaultIpv4Address)
	if err != nil {
		log.Errorln("startTUN error:", err)
		return nil, err
	}
	prefix4 = append(prefix4, tempPrefix4)

	var dnsHijack []string
	if len(cfg.DNSHijack) > 0 {
		dnsHijack = cfg.DNSHijack
	} else {
		dnsHijack = append(dnsHijack, net.JoinHostPort(state.GetDnsServerAddress(), "53"))
	}

	options := LC.Tun{
		Enable:                 true,
		FileDescriptor:         fd,
		Stack:                  cfg.Stack,
		DNSHijack:              dnsHijack,
		Inet4Address:           prefix4,
		EndpointIndependentNat: cfg.EndpointIndependentNat,
		UDPTimeout:             cfg.UDPTimeout,
		DisableICMPForwarding:  cfg.DisableICMPForwarding,
	}

	// The system/mixed-stack NAT forwarder must be bound to the tun interface.
	// FlVpnService excludes our own uid from VPN routing (built-in nodes can't
	// protect their sockets), so without SO_BINDTODEVICE the kernel routes the
	// forwarder's SYN-ACKs by uid rules — out the physical network instead of
	// back into tun — and every TCP flow through the system stack blackholes.
	// mihomo ≤1.19.23 bound the forwarder automatically for fd-based tun;
	// e38aa82a23 removed that, leaving this exported knob (used on Windows).
	sing_tun.EnforceBindInterface = true

	listener, err = sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		log.Errorln("startTUN error:", err)
		return nil, err
	}

	return listener, nil
}
