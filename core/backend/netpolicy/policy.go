// Package netpolicy defines the shared network trust boundary for public
// connectivity probes and transport lists. User subscription/package URLs have
// their own compatible HTTP policy and do not pass through this public-only rule.
package netpolicy

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
)

func PublicIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsValid() || ip.Zone() != "" {
		return false
	}
	if ip.Is4() {
		b := ip.As4()
		a, s := b[0], b[1]
		return a != 0 && a != 10 && a != 127 && a < 224 && !(a == 100 && s >= 64 && s <= 127) && !(a == 169 && s == 254) && !(a == 172 && s >= 16 && s <= 31) && !(a == 192 && s == 0 && (b[2] == 0 || b[2] == 2)) && !(a == 192 && s == 168) && !(a == 192 && s == 88 && b[2] == 99) && !(a == 198 && (s == 18 || s == 19)) && !(a == 198 && s == 51 && b[2] == 100) && !(a == 203 && s == 0 && b[2] == 113)
	}
	return netip.MustParsePrefix("2000::/3").Contains(ip) && !netip.MustParsePrefix("2001:db8::/32").Contains(ip)
}

func ValidateURL(address string) error {
	u, err := url.Parse(address)
	if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Fragment != "" {
		return errors.New("public HTTP(S) URL without credentials or fragment is required")
	}
	if port := u.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return errors.New("invalid endpoint port")
		}
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") || strings.HasSuffix(host, ".home.arpa") {
		return errors.New("private endpoint host")
	}
	if ip, err := netip.ParseAddr(host); err == nil && !PublicIP(ip) {
		return errors.New("private endpoint address")
	}
	return nil
}

type Dialer struct {
	ResolveIPs func(context.Context, string) ([]netip.Addr, error)
	Connect    func(context.Context, string, string) (net.Conn, error)
}

func (d Dialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	var addresses []netip.Addr
	if ip, e := netip.ParseAddr(host); e == nil {
		addresses = []netip.Addr{ip}
	} else if d.ResolveIPs != nil {
		addresses, err = d.ResolveIPs(ctx, host)
	} else {
		addresses, err = net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	}
	if err != nil {
		return nil, err
	}
	if len(addresses) == 0 {
		return nil, errors.New("remote list DNS returned no addresses")
	}
	// Use only public answers, pinning each connection without a second
	// hostname lookup. Mixed DNS answers preserve the legacy public path.
	public := make([]netip.Addr, 0, len(addresses))
	for _, ip := range addresses {
		if PublicIP(ip) {
			public = append(public, ip)
		}
	}
	addresses = public
	if len(addresses) == 0 {
		return nil, errors.New("remote list DNS resolved no public address")
	}
	dial := d.Connect
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}
	for _, ip := range addresses {
		connection, e := dial(ctx, network, net.JoinHostPort(ip.String(), port))
		if e == nil {
			return connection, nil
		}
		err = e
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, err
}
