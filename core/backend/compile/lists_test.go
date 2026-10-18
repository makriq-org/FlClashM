package compile

import (
	"context"
	"crypto/x509"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRemoteListsNetworkPolicyAndStaleCache(t *testing.T) {
	var requests atomic.Int32
	var mode atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		switch mode.Load() {
		case 1:
			w.WriteHeader(503)
		case 2:
			http.Redirect(w, r, "https://example.com/redirected", 302)
		case 3:
			_, _ = w.Write([]byte(strings.Repeat("x", (1<<20)+1)))
		case 4:
			_, _ = w.Write([]byte("--ip 0.0.0.0"))
		default:
			_, _ = w.Write([]byte("# comment\n-d1 -s2\n"))
		}
	}))
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	var private atomic.Bool
	var dials atomic.Int32
	store := &ListStore{Home: t.TempDir(), RootCAs: roots, Now: func() time.Time { return now }, ResolveIPs: func(context.Context, string) ([]netip.Addr, error) {
		if private.Load() {
			return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
		}
		return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
	}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		dials.Add(1)
		if address != "8.8.8.8:443" {
			return nil, errors.New("DNS result was not pinned")
		}
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}}
	request := RemoteListRequest{"byedpi", "https://example.com/list", time.Hour}
	resolve := func() map[string]string {
		t.Helper()
		result, err := store.Resolve(context.Background(), []RemoteListRequest{request})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	key := listKey(request.Kind, request.URL)
	if got := resolve()[key]; got != "# comment\n-d1 -s2\n" {
		t.Fatalf("download %q", got)
	}
	if requests.Load() != 1 {
		t.Fatal("initial request")
	}
	resolve()
	if requests.Load() != 1 {
		t.Fatal("fresh cache refetched")
	}
	for _, failure := range []int32{1, 2, 3, 4} {
		mode.Store(failure)
		now = now.Add(2 * time.Hour)
		if got := resolve()[key]; got != "# comment\n-d1 -s2\n" {
			t.Fatalf("stale fallback failed for mode %d", failure)
		}
	}
	before := dials.Load()
	private.Store(true)
	now = now.Add(2 * time.Hour)
	resolve()
	if dials.Load() != before {
		t.Fatal("private DNS answer reached dialer")
	}
	// No cache: unsafe DNS and unsafe bodies must omit the source.
	if err := os.Remove(store.cachePath(request)); err != nil {
		t.Fatal(err)
	}
	if _, ok := resolve()[key]; ok {
		t.Fatal("private DNS download succeeded without cache")
	}
	private.Store(false)
	if _, ok := resolve()[key]; ok {
		t.Fatal("invalid CLI source cached")
	}
	mode.Store(2)
	beforeRequests := requests.Load()
	resolve()
	if requests.Load() != beforeRequests+1 {
		t.Fatal("redirect followed")
	}
}
func TestRemoteListBatchAndCancellation(t *testing.T) {
	config := Object{"proxies": []any{Object{"name": "a", "type": "byedpi", "strategies": []any{"https://example.com/a", "https://example.com/a"}}, Object{"name": "b", "type": "stormdns", "resolver-policy": Object{"refresh": "1h"}, "resolvers": []any{"https://example.com/b"}}}}
	requests, err := collectRemoteRequests(config)
	if err != nil || len(requests) != 2 || requests[1].Refresh != time.Hour {
		t.Fatalf("collected: %#v %v", requests, err)
	}
	entries := []any{}
	for i := range 33 {
		entries = append(entries, "https://example.com/"+strings.Repeat("a", i+1))
	}
	object(list(config["proxies"])[0])["strategies"] = entries
	if _, err := collectRemoteRequests(config); err == nil {
		t.Fatal("unbounded fanout")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	store := &ListStore{Home: t.TempDir(), ResolveIPs: func(ctx context.Context, _ string) ([]netip.Addr, error) { return nil, ctx.Err() }}
	_, _ = store.Resolve(ctx, requests)
	files, err := os.ReadDir(filepath.Join(store.Home, "runtimes"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if len(files) != 0 {
		t.Fatal("cancelled source persisted")
	}
}
