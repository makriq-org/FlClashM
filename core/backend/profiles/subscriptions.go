package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// HTTPClient is injected by the host: Android uses the engine's tunnel-aware
// HTTP transport; tests use local servers. Subscriptions do not depend on UI IO.
type HTTPClient interface {
	Do(*http.Request) (*http.Response, error)
}
type Subscriptions struct {
	UserAgent     string
	Repository    *Repository
	Client        HTTPClient
	DeviceHeaders func(context.Context) (map[string]string, error)
	Now           func() time.Time
	OnUpdated     func(context.Context, string, uint64) error
	mu            sync.Mutex
	inflight      map[string]bool
}

func (s *Subscriptions) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}
func (s *Subscriptions) Update(ctx context.Context, id string, sendDeviceHeaders bool) (Record, error) {
	if s.Repository == nil || s.Client == nil {
		return Record{}, errors.New("subscription dependencies are required")
	}
	s.mu.Lock()
	if s.inflight == nil {
		s.inflight = map[string]bool{}
	}
	if s.inflight[id] {
		s.mu.Unlock()
		return Record{}, errors.New("subscription update already running")
	}
	s.inflight[id] = true
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(s.inflight, id); s.mu.Unlock() }()
	profile, err := s.Repository.metadata(id)
	if err != nil {
		return Record{}, err
	}
	var address string
	_ = json.Unmarshal(profile.Metadata["url"], &address)
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return Record{}, errors.New("subscription URL must be HTTP(S)")
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return Record{}, err
	}
	userAgent := s.UserAgent
	var patch Object
	_ = json.Unmarshal(s.Repository.Snapshot().Settings["patchClashConfig"], &patch)
	if value, ok := patch["global-ua"]; ok && string(value) != "null" {
		_ = json.Unmarshal(value, &userAgent)
	}
	if userAgent == "" {
		userAgent = "FlClashM"
	}
	request.Header.Set("User-Agent", userAgent)
	if sendDeviceHeaders && s.DeviceHeaders != nil {
		headers, err := s.DeviceHeaders(ctx)
		if err != nil {
			return Record{}, err
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
	}
	response, err := s.Client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return Record{}, ctx.Err()
		}
		return Record{}, errors.New("subscription download failed")
	}
	if response == nil || response.Body == nil {
		return Record{}, errors.New("subscription transport returned no body")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return Record{}, fmt.Errorf("subscription HTTP status %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, MaxProfileBytes+1))
	if err != nil {
		if ctx.Err() != nil {
			return Record{}, ctx.Err()
		}
		return Record{}, errors.New("subscription body read failed")
	}
	if len(raw) > MaxProfileBytes {
		return Record{}, errors.New("subscription exceeds size limit")
	}
	metadata := clone(profile.Metadata)
	incoming := collectProviderHeaders(response.Header)
	previous := map[string]string{}
	_ = json.Unmarshal(metadata["providerHeaders"], &previous)
	merged := MergeProviderHeaders(previous, incoming)
	metadata["providerHeaders"] = mustJSON(merged)
	if interval, err := strconv.ParseInt(incoming["profile-update-interval"], 10, 64); err == nil && interval > 0 && interval <= math.MaxInt64/int64(time.Hour/time.Microsecond) {
		metadata["autoUpdateDuration"] = mustJSON(interval * int64(time.Hour/time.Microsecond))
	}
	domain := ProviderHeader(incoming, "newdomain")
	if domain != "" && parsed.Hostname() != domain {
		// Match Uri.replace(host:...) semantics without permitting a supplied path,
		// scheme, username, or port to be interpreted as part of a new authority.
		if strings.ContainsAny(domain, "/@?#\\ \t\r\n") {
			return Record{}, errors.New("invalid subscription replacement host")
		}
		port := parsed.Port()
		host := domain
		if strings.Contains(domain, ":") {
			address, err := netip.ParseAddr(strings.Trim(domain, "[]"))
			if err != nil {
				return Record{}, errors.New("invalid subscription replacement host")
			}
			domain = address.String()
			host = "[" + domain + "]"
		}
		if port != "" {
			host = net.JoinHostPort(domain, port)
		}
		parsed.Host = host
		metadata["url"] = mustJSON(parsed.String())
	}
	if label, ok := metadata["label"]; !ok || string(label) == "null" {
		label := id
		_, params, parseErr := mime.ParseMediaType(response.Header.Get("Content-Disposition"))
		if parseErr == nil && params["filename"] != "" {
			label = params["filename"]
		}
		metadata["label"] = mustJSON(label)
	}
	info := map[string]int64{"upload": 0, "download": 0, "total": 0, "expire": 0}
	for _, part := range strings.Split(response.Header.Get("subscription-userinfo"), ";") {
		key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		if _, known := info[key]; known {
			n, _ := strconv.ParseInt(value, 10, 64)
			info[key] = n
		}
	}
	metadata["subscriptionInfo"] = mustJSON(info)
	metadata["lastUpdateDate"] = mustJSON(s.now().UTC().Format(time.RFC3339Nano))
	updated, err := s.Repository.Put(ctx, metadata, string(raw), profile.Revision)
	if err != nil {
		return Record{}, err
	}
	if s.OnUpdated != nil {
		if err = s.OnUpdated(ctx, id, updated.Revision); err != nil {
			return updated, err
		}
	}
	return updated, nil
}
func ProviderHeader(headers map[string]string, suffix string) string {
	if value, ok := headers["flclashm-"+suffix]; ok {
		return value
	}
	return headers["flclashx-"+suffix]
}
func collectProviderHeaders(headers http.Header) map[string]string {
	result := map[string]string{}
	for name, values := range headers {
		key := strings.ToLower(name)
		collect := strings.HasPrefix(key, "flclashm-") || strings.HasPrefix(key, "flclashx-")
		switch key {
		case "announce", "support-url", "profile-update-interval", "x-hwid-max-devices-reached", "x-hwid-not-supported":
			collect = true
		}
		if collect && len(values) > 0 && values[0] != "" {
			result[key] = values[0]
		}
	}
	return result
}
func MergeProviderHeaders(previous, incoming map[string]string) map[string]string {
	merged := map[string]string{}
	for k, v := range previous {
		merged[k] = v
	}
	for key := range incoming {
		if strings.HasPrefix(key, "flclashm-") || strings.HasPrefix(key, "flclashx-") {
			_, suffix, _ := strings.Cut(key, "-")
			delete(merged, "flclashm-"+suffix)
			delete(merged, "flclashx-"+suffix)
		}
	}
	for k, v := range incoming {
		merged[k] = v
	}
	for _, key := range []string{"announce", "support-url", "x-hwid-max-devices-reached", "x-hwid-not-supported"} {
		if _, ok := incoming[key]; !ok {
			delete(merged, key)
		}
	}
	return merged
}

// Due is deterministic and independent of Flutter lifecycle. The host owns the
// ticker passed to Run; a fake clock/ticker makes network scenarios reproducible.
func (s *Subscriptions) Due(now time.Time) []string {
	state := s.Repository.Snapshot()
	var ids []string
	for _, profile := range state.Profiles {
		var address string
		_ = json.Unmarshal(profile.Metadata["url"], &address)
		if address == "" {
			continue
		}
		enabled := true
		_ = json.Unmarshal(profile.Metadata["autoUpdate"], &enabled)
		if !enabled {
			continue
		}
		micros := int64(24 * time.Hour / time.Microsecond)
		_ = json.Unmarshal(profile.Metadata["autoUpdateDuration"], &micros)
		var last string
		_ = json.Unmarshal(profile.Metadata["lastUpdateDate"], &last)
		parsed, err := time.Parse(time.RFC3339Nano, last)
		// Avoid overflow of time.Duration for a corrupt legacy interval.
		if micros < 0 {
			continue
		}
		if err == nil && now.UnixMicro()-parsed.UnixMicro() <= micros {
			continue
		}
		id, _ := profileID(profile.Metadata)
		ids = append(ids, id)
	}
	return ids
}
func (s *Subscriptions) Run(ctx context.Context, ticks <-chan time.Time, onError func(string, error)) {
	for {
		select {
		case <-ctx.Done():
			return
		case now, ok := <-ticks:
			if !ok {
				return
			}
			for _, id := range s.Due(now) {
				if ctx.Err() != nil {
					return
				}
				if _, err := s.Update(ctx, id, true); err != nil && onError != nil {
					onError(id, err)
				}
			}
		}
	}
}
