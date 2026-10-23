package compile

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

const maxPackageListBytes = 1 << 20

type packageRefresh struct {
	profile, address string
	attempted        time.Time
}

// PackageListCache preserves the legacy cache-first package-list contract.
// Read never waits for the network when a valid saved list exists. Refresh is
// driven by the application's lifetime-owned scheduler, not by compilation.
type PackageListCache struct {
	ProfilesDir string
	Client      interface {
		Do(*http.Request) (*http.Response, error)
	}
	mu            sync.Mutex
	pending       map[string]packageRefresh
	refreshing    bool
	epoch         uint64
	refreshCancel context.CancelFunc
	flights       singleflight.Group
	// downloads owns shared downloads of the current epoch. A download is not
	// owned by whichever caller started it, and Reset cancels it.
	downloads       context.Context
	cancelDownloads context.CancelFunc
}

func (s *PackageListCache) path(profile, address string) (string, error) {
	if profile == "" || profile == "." || profile == ".." || strings.ContainsAny(profile, "/\\\x00") || !isHTTPURL(address) {
		return "", errors.New("invalid package list identity")
	}
	return filepath.Join(s.ProfilesDir, "providers", profile, "packages", md5Text(address)), nil
}

func (s *PackageListCache) Read(ctx context.Context, profile, address string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	name, err := s.path(profile, address)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	if s.pending == nil {
		s.pending = map[string]packageRefresh{}
	}
	if _, exists := s.pending[name]; !exists && len(s.pending) < 512 {
		request := packageRefresh{profile: profile, address: address}
		for _, other := range s.pending {
			if other.address == address && other.attempted.After(request.attempted) {
				request.attempted = other.attempted
			}
		}
		s.pending[name] = request
	}
	s.mu.Unlock()
	// Validation uses a temporary profile ID. The URL identifies the same list
	// across profiles, so it can also reuse an existing legacy/source cache.
	others, _ := filepath.Glob(filepath.Join(s.ProfilesDir, "providers", "*", "packages", md5Text(address)))
	for _, candidate := range append([]string{name}, others...) {
		file, err := os.Open(candidate)
		if err != nil {
			continue
		}
		body, err := io.ReadAll(io.LimitReader(file, maxPackageListBytes+1))
		_ = file.Close()
		if err == nil && len(body) <= maxPackageListBytes {
			if _, err = parsePackageBody(string(body)); err == nil {
				return string(body), ctx.Err()
			}
		}
	}
	return s.fetch(ctx, name, address)
}

func (s *PackageListCache) fetch(ctx context.Context, name, address string) (string, error) {
	s.mu.Lock()
	epoch := s.epoch
	if s.downloads == nil {
		s.downloads, s.cancelDownloads = context.WithCancel(context.Background())
	}
	downloads := s.downloads
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	ready := s.flights.DoChan(address, func() (any, error) {
		// Each waiter honors its own context below; cancelling the first caller
		// must not fail every other caller waiting for the same list.
		ctx, cancel := context.WithTimeout(downloads, 20*time.Second)
		defer cancel()
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
		if err != nil {
			return "", err
		}
		client := s.Client
		if client == nil {
			client = http.DefaultClient
		}
		response, err := client.Do(request)
		if err != nil {
			return "", err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return "", errors.New("package list download failed")
		}
		raw, err := io.ReadAll(io.LimitReader(response.Body, maxPackageListBytes+1))
		if err != nil {
			return "", err
		}
		if len(raw) > maxPackageListBytes {
			return "", errors.New("package list too large")
		}
		body := strings.ToValidUTF8(string(raw), "\uFFFD")
		if _, err = parsePackageBody(body); err != nil {
			return "", err
		}
		return body, nil
	})
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case result := <-ready:
		if result.Err != nil {
			return "", result.Err
		}
		if err := ctx.Err(); err != nil {
			return "", err
		}
		body := result.Val.(string)
		s.mu.Lock()
		defer s.mu.Unlock()
		if epoch != s.epoch {
			return "", context.Canceled
		}
		// Cache failure must not reject a successfully validated download.
		_ = savePackageList(name, body)
		if pending, ok := s.pending[name]; ok {
			pending.attempted = time.Now()
			s.pending[name] = pending
		}
		return body, nil
	}
}

func savePackageList(name, body string) error {
	if err := os.MkdirAll(filepath.Dir(name), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(name), ".packages-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err = file.WriteString(body); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), name)
}

func (s *PackageListCache) Refresh(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	s.mu.Lock()
	if s.refreshing {
		s.mu.Unlock()
		return
	}
	s.refreshing = true
	s.refreshCancel = cancel
	epoch := s.epoch
	queue := make(chan string, len(s.pending))
	for name, request := range s.pending {
		if time.Since(request.attempted) >= 15*time.Minute {
			queue <- name
		}
	}
	close(queue)
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.refreshing = false; s.refreshCancel = nil; s.mu.Unlock() }()
	var workers sync.WaitGroup
	for range 4 {
		workers.Go(func() {
			for name := range queue {
				if ctx.Err() != nil {
					return
				}
				s.mu.Lock()
				request, exists := s.pending[name]
				if !exists || epoch != s.epoch {
					s.mu.Unlock()
					return
				}
				request.attempted = time.Now()
				s.pending[name] = request
				s.mu.Unlock()
				_, _ = s.fetch(ctx, name, request.address)
			}
		})
	}
	workers.Wait()
}

// Erasure fences cache writes before the application removes profile files.
func (s *PackageListCache) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.epoch++
	for _, request := range s.pending {
		s.flights.Forget(request.address)
	}
	s.pending = nil
	if s.refreshCancel != nil {
		s.refreshCancel()
	}
	if s.cancelDownloads != nil {
		s.cancelDownloads()
		s.downloads, s.cancelDownloads = nil, nil
	}
}
