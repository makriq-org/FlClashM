package compile

import (
	"context"
	"core/backend/netpolicy"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type RemoteListRequest struct {
	Kind, URL string
	Refresh   time.Duration
}
type RemoteLists interface {
	Resolve(context.Context, []RemoteListRequest) (map[string]string, error)
}

func listKey(kind, address string) string { return kind + ":" + address }

// ListStore shares the legacy cache representation, with bounded downloads,
// stale-on-error fallback, public-address pinning and no redirects. DialContext
// can protect sockets on Android; ResolveIPs can use the platform's physical DNS.
type ListStore struct {
	RootCAs        *x509.CertPool
	Home           string
	LegacyTimeZone *time.Location
	Now            func() time.Time
	ResolveIPs     func(context.Context, string) ([]netip.Addr, error)
	DialContext    func(context.Context, string, string) (net.Conn, error)
}
type cachedList struct {
	URL       string    `json:"url"`
	Body      string    `json:"body"`
	FetchedAt time.Time `json:"fetchedAt"`
}

// Dart's DateTime.now().toIso8601String() stored local timestamps without an
// offset. Read those in the migration zone; new cache writes remain RFC3339 UTC.
func decodeCachedList(raw []byte, zone *time.Location) (cachedList, error) {
	var stored struct {
		URL       string `json:"url"`
		Body      string `json:"body"`
		FetchedAt string `json:"fetchedAt"`
	}
	if err := json.Unmarshal(raw, &stored); err != nil {
		return cachedList{}, err
	}
	fetchedAt, err := time.Parse(time.RFC3339Nano, stored.FetchedAt)
	if err != nil {
		if zone == nil {
			zone = time.Local
		}
		fetchedAt, err = time.ParseInLocation("2006-01-02T15:04:05.999999999", stored.FetchedAt, zone)
	}
	return cachedList{URL: stored.URL, Body: stored.Body, FetchedAt: fetchedAt}, err
}

func (s *ListStore) Resolve(ctx context.Context, requests []RemoteListRequest) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	result := map[string]string{}
	var mu sync.Mutex
	queue := make(chan RemoteListRequest, len(requests))
	for _, req := range requests {
		queue <- req
	}
	close(queue)
	var workers sync.WaitGroup
	for range min(8, len(requests)) {
		workers.Go(func() {
			for req := range queue {
				body, ok := s.read(ctx, req)
				if ok {
					mu.Lock()
					result[listKey(req.Kind, req.URL)] = body
					mu.Unlock()
				}
			}
		})
	}
	workers.Wait()
	// A batch deadline omits missing sources but cancellation of the parent
	// operation must still abort compilation (checked by the caller).
	return result, nil
}
func (s *ListStore) cachePath(req RemoteListRequest) string {
	sum := sha256.Sum256([]byte(req.URL))
	directory := "strategy-lists"
	if req.Kind == "stormdns" {
		directory = "resolver-lists"
	}
	return filepath.Join(s.Home, "runtimes", req.Kind, directory, hex.EncodeToString(sum[:])+".json")
}
func (s *ListStore) read(ctx context.Context, req RemoteListRequest) (string, bool) {
	if req.Kind != "byedpi" && req.Kind != "stormdns" {
		return "", false
	}
	if publicListURL(req.URL) != nil {
		return "", false
	}
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	var cached cachedList
	hasCached := false
	if s.Home != "" {
		if f, err := os.Open(s.cachePath(req)); err == nil {
			body, e := io.ReadAll(io.LimitReader(f, (2<<20)+1))
			_ = f.Close()
			if e == nil && len(body) <= 2<<20 {
				cached, e = decodeCachedList(body, s.LegacyTimeZone)
				hasCached = e == nil && cached.URL == req.URL && validRemoteBody(req.Kind, cached.Body) == nil && !cached.FetchedAt.IsZero()
			}
		}
	}
	if hasCached && now().Sub(cached.FetchedAt) < req.Refresh {
		return cached.Body, true
	}
	body, err := s.download(ctx, req.URL)
	if err == nil {
		err = validRemoteBody(req.Kind, body)
	}
	if err != nil {
		if hasCached {
			return cached.Body, true
		}
		return "", false
	}
	if s.Home != "" && ctx.Err() == nil {
		data, _ := json.Marshal(cachedList{req.URL, body, now().UTC()})
		_ = writeListCache(s.cachePath(req), data)
	}
	return body, true
}
func validRemoteBody(kind, body string) error {
	if len(body) > 1<<20 || !utf8.ValidString(body) {
		return errors.New("invalid remote text list")
	}
	if kind == "byedpi" {
		count := 0
		for _, line := range strings.Split(body, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if _, err := CLIArguments(line, "strategy"); err != nil {
				return err
			}
			count++
			if count >= 4096 {
				break
			}
		}
	}
	return nil
}
func writeListCache(name string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(name), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(name), ".list-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	if err == nil {
		err = file.Close()
	}
	if err == nil {
		err = os.Rename(file.Name(), name)
	}
	return err
}
func (s *ListStore) download(ctx context.Context, address string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	transport := &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: s.RootCAs, MinVersion: tls.VersionTLS12}, DisableKeepAlives: true, ResponseHeaderTimeout: 15 * time.Second}
	defer transport.CloseIdleConnections()
	transport.DialContext = (netpolicy.Dialer{ResolveIPs: s.ResolveIPs, Connect: s.DialContext}).DialContext
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("remote list redirects are forbidden") }}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("remote list HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
	if err != nil {
		return "", err
	}
	if len(body) > 1<<20 {
		return "", errors.New("remote list exceeds size limit")
	}
	return strings.ToValidUTF8(string(body), "\uFFFD"), nil
}

// collectRemoteRequests validates source URLs before any network request and
// combines duplicate URLs at the shortest declared refresh interval.
func collectRemoteRequests(config Object) ([]RemoteListRequest, error) {
	requests := []RemoteListRequest{}
	indices := map[string]int{}
	counts := map[string]int{}
	for _, slot := range proxySlots(config) {
		entry := slot.values[slot.index]
		raw := object(entry)
		kind := strings.ToLower(strings.TrimSpace(text(raw["type"])))
		if kind != "byedpi" && kind != "stormdns" {
			continue
		}
		raw, err := normalizeNode(raw, kind)
		if err != nil {
			return nil, err
		}
		refresh := 24 * time.Hour
		key := "strategies"
		if kind == "stormdns" {
			key = "resolvers"
			refresh, err = stormFieldDuration("resolver-policy.refresh", object(raw["resolver-policy"])["refresh"], refresh)
			if err != nil {
				return nil, err
			}
		}
		if v, ok := raw[key]; ok {
			if _, valid := v.([]any); !valid {
				return nil, fmt.Errorf("%s requires a source list", key)
			}
		}
		for _, v := range list(raw[key]) {
			address := strings.TrimSpace(text(v))
			u, e := url.Parse(address)
			remote := e == nil && u.Scheme != "" && strings.Contains(address, "://")
			if !remote {
				continue
			}
			if err := publicListURL(address); err != nil {
				return nil, err
			}
			id := listKey(kind, address)
			if i, ok := indices[id]; ok {
				if refresh < requests[i].Refresh {
					requests[i].Refresh = refresh
				}
				continue
			}
			counts[kind]++
			if counts[kind] > 32 {
				return nil, errors.New("too many external remote lists")
			}
			indices[id] = len(requests)
			requests = append(requests, RemoteListRequest{kind, address, refresh})
		}
	}
	return requests, nil
}

type resolvedLists map[string]string

func (r resolvedLists) Read(ctx context.Context, kind, address string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	body, ok := r[listKey(kind, address)]
	if !ok {
		return "", errors.New("remote list unavailable")
	}
	return body, nil
}
