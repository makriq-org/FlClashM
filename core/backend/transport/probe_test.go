package transport

import (
	"context"
	"crypto/x509"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"core/backend"
	"core/backend/netpolicy"
	"github.com/miekg/dns"
)

func testSOCKS(t *testing.T, target string, seen chan<- string, requireAuth bool) (string, int) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(5 * time.Second))
				header := make([]byte, 2)
				if _, err := io.ReadFull(c, header); err != nil {
					return
				}
				methods := make([]byte, int(header[1]))
				if _, err = io.ReadFull(c, methods); err != nil {
					return
				}
				method := byte(255)
				for _, candidate := range methods {
					if candidate == 2 {
						method = 2
						break
					}
					if candidate == 0 && !requireAuth {
						method = 0
					}
				}
				_, _ = c.Write([]byte{5, method})
				if method == 255 {
					return
				}
				if method == 2 {
					var authHeader [2]byte
					if _, err = io.ReadFull(c, authHeader[:]); err != nil || authHeader[0] != 1 {
						return
					}
					user := make([]byte, int(authHeader[1]))
					if _, err = io.ReadFull(c, user); err != nil {
						return
					}
					var passLength [1]byte
					if _, err = io.ReadFull(c, passLength[:]); err != nil {
						return
					}
					password := make([]byte, int(passLength[0]))
					if _, err = io.ReadFull(c, password); err != nil {
						return
					}
					authStatus := byte(1)
					if string(user) == "service-user" && string(password) == "service-password" {
						authStatus = 0
					}
					if _, err = c.Write([]byte{1, authStatus}); err != nil || authStatus != 0 {
						return
					}
				}
				request := make([]byte, 4)
				if _, err = io.ReadFull(c, request); err != nil {
					return
				}
				host := ""
				switch request[3] {
				case 1:
					raw := make([]byte, 4)
					if _, err = io.ReadFull(c, raw); err != nil {
						return
					}
					host = net.IP(raw).String()
				case 4:
					raw := make([]byte, 16)
					if _, err = io.ReadFull(c, raw); err != nil {
						return
					}
					host = net.IP(raw).String()
				case 3:
					raw := []byte{0}
					if _, err = io.ReadFull(c, raw); err != nil {
						return
					}
					name := make([]byte, int(raw[0]))
					if _, err = io.ReadFull(c, name); err != nil {
						return
					}
					host = string(name)
				default:
					return
				}
				port := make([]byte, 2)
				if _, err = io.ReadFull(c, port); err != nil {
					return
				}
				seen <- net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(port))))
				remote, err := net.DialTimeout("tcp", target, time.Second)
				if err != nil {
					return
				}
				defer remote.Close()
				_, _ = c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0})
				go func() { _, _ = io.Copy(remote, c); remote.Close() }()
				_, _ = io.Copy(c, remote)
			}(connection)
		}
	}()
	addr := listener.Addr().(*net.TCPAddr)
	return "127.0.0.1", addr.Port
}

func TestSOCKSProbeUsesServiceCredentials(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Errorf("probe changed HTTP method: %s", r.Method)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer origin.Close()
	probes := make(chan string, 1)
	host, port := testSOCKS(t, origin.Listener.Addr().String(), probes, true)
	request := backend.NodeProbe{
		ID:       "node",
		Host:     host,
		Port:     port,
		URL:      "http://example.com/check",
		Resolver: "system",
		Username: "service-user",
		Password: "service-password",
	}
	adapter := ProcessAdapter{Prober: &SOCKSProbe{}, processes: map[string]*process{
		request.ID: {address: net.JoinHostPort(host, strconv.Itoa(port)), done: make(chan struct{})},
	}}
	passed, err := adapter.Probe(context.Background(), request)
	if err != nil || !passed {
		t.Fatalf("authenticated SOCKS probe: passed=%v err=%v", passed, err)
	}
	if target := <-probes; target != "example.com:80" {
		t.Fatalf("SOCKS target %q", target)
	}
}

func TestSOCKSProbeStopsWritingWhenLaunchExits(t *testing.T) {
	done := make(chan struct{})
	const address = "127.0.0.1:1080"
	adapter := ProcessAdapter{processes: map[string]*process{"node": {address: address, done: done}}}
	check, err := adapter.watchProcess("node", address)
	if err != nil {
		t.Fatal(err)
	}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	close(done)
	if err := client.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	n, err := (&processConn{Conn: client, check: check}).Write([]byte{1, 1, 'u', 1, 'p'})
	if n != 0 || err == nil || err.Error() != "external process exited" {
		t.Fatalf("write was not fenced by the process exit: wrote %d, err %v", n, err)
	}
}

func TestSOCKSProbeTLSDoHAndDomainFallback(t *testing.T) {
	var originRequests atomic.Int32
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		originRequests.Add(1)
		if r.Method != http.MethodHead {
			t.Error("probe changed HTTP method")
		}
		w.WriteHeader(503)
	}))
	defer origin.Close()
	var dnsMode atomic.Int32
	var dnsRequests atomic.Int32
	doh := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dnsRequests.Add(1)
		if dnsMode.Load() == 1 {
			w.WriteHeader(503)
			return
		}
		body, _ := io.ReadAll(r.Body)
		question := new(dns.Msg)
		if question.Unpack(body) != nil {
			w.WriteHeader(400)
			return
		}
		answer := new(dns.Msg)
		answer.SetReply(question)
		address := net.IPv4(8, 8, 8, 8)
		if dnsMode.Load() == 2 {
			address = net.IPv4(127, 0, 0, 1)
		}
		answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: question.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: address}}
		wire, _ := answer.Pack()
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(wire)
	}))
	defer doh.Close()
	roots := x509.NewCertPool()
	roots.AddCert(origin.Certificate())
	roots.AddCert(doh.Certificate())
	probes := make(chan string, 8)
	host, port := testSOCKS(t, origin.Listener.Addr().String(), probes, false)
	dohPort := doh.Listener.Addr().(*net.TCPAddr).Port
	originPort := origin.Listener.Addr().(*net.TCPAddr).Port
	prober := &SOCKSProbe{RootCAs: roots, Direct: netpolicy.Dialer{ResolveIPs: func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("9.9.9.9")}, nil
	}, Connect: func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != net.JoinHostPort("9.9.9.9", strconv.Itoa(dohPort)) {
			t.Errorf("DoH address not pinned: %s", address)
		}
		return (&net.Dialer{}).DialContext(ctx, network, doh.Listener.Addr().String())
	}}}
	request := backend.NodeProbe{Host: host, Port: port, URL: "https://example.com:" + strconv.Itoa(originPort) + "/check", Resolver: "https://example.com:" + strconv.Itoa(dohPort) + "/dns-query"}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	passed, err := prober.Probe(ctx, request)
	if err != nil || !passed {
		t.Fatal("TLS/HTTP status compatibility", passed, err)
	}
	if target := <-probes; target != net.JoinHostPort("8.8.8.8", strconv.Itoa(originPort)) {
		t.Fatal("DoH target", target)
	}
	_, _ = prober.Probe(ctx, request)
	<-probes
	if dnsRequests.Load() != 1 {
		t.Fatal("DoH cache not shared between checks")
	}
	dnsMode.Store(1)
	prober.ClearDNSCache()
	passed, err = prober.Probe(ctx, request)
	if err != nil || !passed {
		t.Fatal("DoH failure must permit SOCKS domain fallback", passed, err)
	}
	if target := <-probes; target != net.JoinHostPort("example.com", strconv.Itoa(originPort)) {
		t.Fatal("fallback target", target)
	}
	dnsMode.Store(2)
	prober.ClearDNSCache()
	passed, err = prober.Probe(ctx, request)
	if err == nil || passed {
		t.Fatal("private DoH answer used", passed, err)
	}
	if len(probes) != 0 || originRequests.Load() != 3 {
		t.Fatal("private answer reached SOCKS")
	}
	request.URL = "https://127.0.0.1/check"
	if passed, err = prober.Probe(ctx, request); err == nil || passed {
		t.Fatal("private URL accepted")
	}
}

func TestStrategyProbeRejectsHTTPFailuresWithoutChangingConnectivityChecks(t *testing.T) {
	var status atomic.Int32
	status.Store(403)
	methods := make(chan string, 4)
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { methods <- r.Method; w.WriteHeader(int(status.Load())) }))
	defer origin.Close()
	roots := x509.NewCertPool()
	roots.AddCert(origin.Certificate())
	targets := make(chan string, 4)
	host, port := testSOCKS(t, origin.Listener.Addr().String(), targets, false)
	probe := SOCKSProbe{RootCAs: roots}
	request := backend.NodeProbe{Host: host, Port: port, URL: "https://example.com:" + strconv.Itoa(origin.Listener.Addr().(*net.TCPAddr).Port) + "/check", Resolver: "system"}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if ok, err := probe.Probe(ctx, request); err != nil || !ok {
		t.Fatal("ordinary connectivity changed", ok, err)
	}
	if method := <-methods; method != http.MethodHead {
		t.Fatal(method)
	}
	request.RequireSuccess = true
	if ok, err := probe.Probe(ctx, request); err != nil || ok {
		t.Fatal("block response verified a strategy", ok, err)
	}
	if method := <-methods; method != http.MethodGet {
		t.Fatal(method)
	}
	status.Store(http.StatusFound)
	if ok, err := probe.Probe(ctx, request); err != nil || ok {
		t.Fatal("redirect verified a strategy", ok, err)
	}
	status.Store(204)
	if ok, err := probe.Probe(ctx, request); err != nil || !ok {
		t.Fatal("working strategy rejected", ok, err)
	}
}
