package compile

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

const stormSystemDNS = "# @flclashm:system-dns"
const maxResolverHosts = 65536

type resolver struct {
	ip   netip.Addr
	port uint16
}

func (r resolver) line() string {
	if r.port == 53 {
		return r.ip.String()
	}
	return net.JoinHostPort(r.ip.String(), strconv.Itoa(int(r.port)))
}
func expandResolverLiteral(value string) ([]resolver, error) {
	value = strings.TrimSpace(value)
	port := uint16(53)
	target := value
	parse := func(s string) (netip.Prefix, error) {
		if p, err := netip.ParsePrefix(s); err == nil {
			return p, nil
		}
		if a, err := netip.ParseAddr(s); err == nil && a.Zone() == "" {
			return netip.PrefixFrom(a, a.BitLen()), nil
		}
		return netip.Prefix{}, errors.New("not an address or prefix")
	}
	prefix, err := parse(target)
	if err != nil {
		host, p, e := net.SplitHostPort(value)
		if e != nil {
			if strings.Count(value, ":") == 1 {
				host, p, _ = strings.Cut(value, ":")
			} else {
				return nil, err
			}
		}
		n, e := strconv.Atoi(p)
		if e != nil || n < 1 || n > 65535 {
			return nil, errors.New("invalid resolver port")
		}
		port = uint16(n)
		prefix, err = parse(host)
		if err != nil {
			return nil, err
		}
	}
	if prefix.Addr().Zone() != "" {
		return nil, errors.New("resolver zone is unsupported")
	}
	hostBits := prefix.Addr().BitLen() - prefix.Bits()
	if hostBits > 16 {
		return nil, errors.New("resolver prefix exceeds host limit")
	}
	count := 1 << hostBits
	current := prefix.Masked().Addr()
	if prefix.Addr().Is4() && hostBits > 1 {
		count -= 2
		current = current.Next()
	} else if prefix.Addr().Is6() && hostBits > 1 {
		count--
		current = current.Next()
	}
	entries := make([]resolver, 0, count)
	for range count {
		entries = append(entries, resolver{current.Unmap(), port})
		current = current.Next()
	}
	return entries, nil
}
func (e *ExternalCompiler) stormResolverLines(ctx context.Context, value any, refresh time.Duration) ([]string, error) {
	values := list(value)
	if value == nil || len(values) == 0 {
		values = []any{"system"}
	}
	sources := make([][]resolver, 0, len(values))
	markers := map[int]bool{}
	hasSystem := false
	for i, v := range values {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		s, ok := v.(string)
		if !ok || strings.TrimSpace(s) == "" {
			return nil, errors.New("resolver sources require nonempty strings")
		}
		s = strings.TrimSpace(s)
		if strings.EqualFold(s, "system") {
			markers[i] = true
			hasSystem = true
			sources = append(sources, nil)
			continue
		}
		if strings.Contains(s, "://") || strings.HasPrefix(strings.ToLower(s), "http") {
			if err := publicListURL(s); err != nil {
				return nil, err
			}
			entries := []resolver{}
			if e.Lists != nil {
				body, err := e.Lists.Read(ctx, "stormdns", s)
				if err != nil && ctx.Err() != nil {
					return nil, ctx.Err()
				}
				if err == nil {
					for _, line := range strings.Split(body, "\n") {
						line = strings.TrimSpace(line)
						if line == "" || strings.HasPrefix(line, "#") {
							continue
						}
						parsed, err := expandResolverLiteral(line)
						if err != nil {
							continue
						}
						remaining := maxResolverHosts - len(entries)
						if len(parsed) > remaining {
							parsed = parsed[:remaining]
						}
						entries = append(entries, parsed...)
						if len(entries) >= maxResolverHosts {
							break
						}
					}
				}
			}
			sources = append(sources, entries)
			continue
		}
		entries, err := expandResolverLiteral(s)
		if err != nil {
			return nil, fmt.Errorf("resolver %q: %w", s, err)
		}
		sources = append(sources, entries)
	}
	limit := maxResolverHosts
	if hasSystem {
		limit -= 16
	}
	lines := []string{}
	seen := map[netip.Addr]bool{}
	marked := false
	for i, entries := range sources {
		if markers[i] && !marked {
			lines = append(lines, stormSystemDNS)
			marked = true
		}
		for _, entry := range entries {
			if len(seen) >= limit {
				break
			}
			if !seen[entry.ip] {
				seen[entry.ip] = true
				lines = append(lines, entry.line())
			}
		}
	}
	if len(lines) == 0 {
		return nil, errors.New("StormDNS resolved no resolvers")
	}
	return lines, nil
}
