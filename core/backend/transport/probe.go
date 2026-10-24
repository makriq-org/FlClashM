package transport

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"core/backend"
	"core/backend/netpolicy"
	"github.com/miekg/dns"
	"golang.org/x/net/proxy"
	"golang.org/x/sync/singleflight"
)

type dnsEntry struct {
	addresses []netip.Addr
	expires   time.Time
}

// SOCKSProbe performs one HTTP HEAD exchange, with origin certificate checking.
// Counts, thresholds, retry budgets and decisions belong to RuntimeCoordinator.
type SOCKSProbe struct {
	epoch   uint64
	Direct  netpolicy.Dialer
	RootCAs *x509.CertPool
	mu      sync.Mutex
	cache   map[string]dnsEntry
	flights singleflight.Group
}

func (p *SOCKSProbe) ClearDNSCache() {
	p.mu.Lock()
	p.cache = nil
	p.epoch++
	p.mu.Unlock()
}
func (p *SOCKSProbe) Probe(ctx context.Context, request backend.NodeProbe) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	if request.Host != "127.0.0.1" || request.Port < 1 || request.Port > 65535 {
		return false, errors.New("probe requires a loopback SOCKS listener")
	}
	if err := netpolicy.ValidateURL(request.URL); err != nil {
		return false, err
	}
	endpoint, err := url.Parse(request.URL)
	if err != nil {
		return false, err
	}
	resolver := strings.TrimSpace(request.Resolver)
	if resolver == "" {
		resolver = "https://1.1.1.1/dns-query"
	}
	target := endpoint.Hostname()
	if ip, e := netip.ParseAddr(target); e == nil {
		if !netpolicy.PublicIP(ip) {
			return false, errors.New("private probe address")
		}
	} else if !strings.EqualFold(resolver, "system") {
		if err = netpolicy.ValidateURL(resolver); err != nil {
			return false, err
		}
		u, _ := url.Parse(resolver)
		if u.Scheme != "https" {
			return false, errors.New("probe resolver requires HTTPS")
		}
		answers := p.resolve(ctx, resolver, target)
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		if len(answers) > 0 {
			target = ""
			for _, ip := range answers {
				if netpolicy.PublicIP(ip) {
					target = ip.String()
					break
				}
			}
			if target == "" {
				return false, errors.New("probe DNS returned only private addresses")
			}
		}
		// Unreachable/empty DoH retains the compatible SOCKS domain fallback.
	}
	port := endpoint.Port()
	if port == "" {
		port = "443"
		if endpoint.Scheme == "http" {
			port = "80"
		}
	}
	socksAddress := net.JoinHostPort(request.Host, strconv.Itoa(request.Port))
	dialer, err := proxy.SOCKS5("tcp", socksAddress, nil, &net.Dialer{})
	if err != nil {
		return false, err
	}
	transport := &http.Transport{DisableKeepAlives: true, MaxResponseHeaderBytes: 8 << 10, TLSClientConfig: &tls.Config{RootCAs: p.RootCAs, MinVersion: tls.VersionTLS12}}
	defer transport.CloseIdleConnections()
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return dialer.(proxy.ContextDialer).DialContext(ctx, network, net.JoinHostPort(target, port))
	}
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	method := http.MethodHead
	if request.RequireSuccess {
		method = http.MethodGet
	}
	head, err := http.NewRequestWithContext(ctx, method, request.URL, nil)
	if err != nil {
		return false, err
	}
	head.Header.Set("Connection", "close")
	response, err := client.Do(head)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if request.RequireSuccess {
		// A block page or server error must not certify a working DPI strategy.
		return response.StatusCode >= 200 && response.StatusCode < 400, nil
	}
	// A valid HTTP response, including 4xx/5xx, proves connectivity in the
	// established profile contract. Probes do not interpret application status.
	return response.StatusCode >= 100 && response.StatusCode <= 599, nil
}
func (p *SOCKSProbe) resolve(ctx context.Context, resolver, host string) []netip.Addr {
	p.mu.Lock()
	epoch := p.epoch
	key := strconv.FormatUint(epoch, 10) + "|" + resolver + "|" + host
	entry, ok := p.cache[key]
	p.mu.Unlock()
	if ok && time.Now().Before(entry.expires) {
		return append([]netip.Addr(nil), entry.addresses...)
	}
	// Coalesce concurrent strategies without retaining their operation after all
	// callers cancel: the initiating request supplies the bounded network context.
	result := p.flights.DoChan(key, func() (any, error) {
		budget := 3 * time.Second
		if deadline, ok := ctx.Deadline(); ok {
			budget = time.Until(deadline) / 2
			if budget < time.Second {
				budget = time.Second
			}
			if budget > 3*time.Second {
				budget = 3 * time.Second
			}
		}
		queryCtx, cancel := context.WithTimeout(ctx, budget)
		defer cancel()
		answers, _ := p.queryDNS(queryCtx, resolver, host)
		if ctx.Err() == nil {
			ttl := time.Minute
			if len(answers) == 0 {
				ttl = 10 * time.Second
			}
			p.mu.Lock()
			if p.epoch != epoch {
				p.mu.Unlock()
				return answers, nil
			}
			if p.cache == nil || len(p.cache) >= 32 {
				p.cache = map[string]dnsEntry{}
			}
			p.cache[key] = dnsEntry{addresses: append([]netip.Addr(nil), answers...), expires: time.Now().Add(ttl)}
			p.mu.Unlock()
		}
		return answers, nil
	})
	select {
	case <-ctx.Done():
		return nil
	case value := <-result:
		if value.Err != nil {
			return nil
		}
		return value.Val.([]netip.Addr)
	}
}
func (p *SOCKSProbe) queryDNS(ctx context.Context, resolver, host string) ([]netip.Addr, error) {
	query := new(dns.Msg)
	query.SetQuestion(dns.Fqdn(host), dns.TypeA)
	body, err := query.Pack()
	if err != nil {
		return nil, err
	}
	transport := &http.Transport{DisableKeepAlives: true, MaxResponseHeaderBytes: 8 << 10, DialContext: p.Direct.DialContext, TLSClientConfig: &tls.Config{RootCAs: p.RootCAs, MinVersion: tls.VersionTLS12}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, resolver, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/dns-message")
	request.Header.Set("Content-Type", "application/dns-message")
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, errors.New("DoH HTTP response failed")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, (72<<10)+1))
	if err != nil || len(raw) > 72<<10 {
		return nil, errors.New("invalid DoH response length")
	}
	answer := new(dns.Msg)
	if err = answer.Unpack(raw); err != nil || answer.Id != query.Id || !answer.Response || answer.Rcode != dns.RcodeSuccess {
		return nil, errors.New("invalid DoH response")
	}
	addresses := []netip.Addr{}
	for _, record := range answer.Answer {
		switch v := record.(type) {
		case *dns.A:
			if ip, ok := netip.AddrFromSlice(v.A); ok {
				addresses = append(addresses, ip.Unmap())
			}
		case *dns.AAAA:
			if ip, ok := netip.AddrFromSlice(v.AAAA); ok {
				addresses = append(addresses, ip.Unmap())
			}
		}
	}
	return addresses, nil
}
