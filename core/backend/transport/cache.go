package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"core/backend"
)

var scopeName = regexp.MustCompile(`^[a-z0-9_-]{1,64}$`)

type CacheStore struct {
	Home, ABI      string
	LegacyTimeZone *time.Location
	mu             sync.Mutex
}

func (s *CacheStore) path(id, scope string) (string, error) {
	if !nodeID.MatchString(id) || !strings.HasPrefix(id, "byedpi-") || strings.Contains(id, "-probe-") || !scopeName.MatchString(scope) {
		return "", errors.New("invalid strategy cache identity")
	}
	if s.ABI != "arm64-v8a" && s.ABI != "armeabi-v7a" && s.ABI != "x86_64" && s.ABI != "x86" && s.ABI != "host" {
		return "", errors.New("unsupported cache ABI")
	}
	return filepath.Join(s.Home, "runtimes", "byedpi", s.ABI, "nodes", id, "strategy-cache-"+scope+".json"), nil
}
func (s *CacheStore) Read(ctx context.Context, id, scope string) (backend.StrategyCache, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return backend.StrategyCache{}, err
	}
	name, err := s.path(id, scope)
	if err != nil {
		return backend.StrategyCache{}, err
	}
	value, err := s.read(name)
	if !errors.Is(err, os.ErrNotExist) {
		return value, err
	}
	legacy := filepath.Join(filepath.Dir(name), "strategy-cache.json")
	value, err = s.read(legacy)
	if err != nil {
		return backend.StrategyCache{}, err
	}
	if err = ctx.Err(); err != nil {
		return backend.StrategyCache{}, err
	}
	value.Version = 1
	raw, err := json.Marshal(value)
	if err != nil {
		return backend.StrategyCache{}, err
	}
	if err = writePrivate(name, raw); err != nil {
		return backend.StrategyCache{}, err
	}
	_ = os.Remove(legacy)
	return value, nil
}
func (s *CacheStore) read(name string) (backend.StrategyCache, error) {
	file, err := os.Open(name)
	if err != nil {
		return backend.StrategyCache{}, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		return backend.StrategyCache{}, errors.New("invalid strategy cache size")
	}
	var fields map[string]json.RawMessage
	if err = json.Unmarshal(raw, &fields); err != nil {
		return backend.StrategyCache{}, err
	}
	var version int
	_ = json.Unmarshal(fields["version"], &version)
	if version != 0 && version != 1 {
		return backend.StrategyCache{}, errors.New("unsupported strategy cache version")
	}
	var timestamp string
	if json.Unmarshal(fields["checkedAt"], &timestamp) != nil {
		return backend.StrategyCache{}, errors.New("invalid strategy cache timestamp")
	}
	checkedAt, err := time.Parse(time.RFC3339Nano, timestamp)
	if err != nil {
		zone := s.LegacyTimeZone
		if zone == nil {
			zone = time.Local
		}
		checkedAt, err = time.ParseInLocation("2006-01-02T15:04:05.999999999", timestamp, zone)
		if err != nil {
			return backend.StrategyCache{}, err
		}
	}
	normalized, _ := json.Marshal(checkedAt.UTC())
	fields["checkedAt"] = normalized
	raw, _ = json.Marshal(fields)
	var value backend.StrategyCache
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&value); err != nil {
		return backend.StrategyCache{}, err
	}
	if len(value.Fingerprint) != 64 || strings.Trim(value.Fingerprint, "0123456789abcdef") != "" || value.Strategy == "" || value.Failures < 0 || value.NextIndex < 0 {
		return backend.StrategyCache{}, errors.New("invalid strategy cache contents")
	}
	return value, nil
}
func (s *CacheStore) Write(ctx context.Context, id, scope string, value backend.StrategyCache) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	name, err := s.path(id, scope)
	if err != nil {
		return err
	}
	// Never overwrite a cache owned by a future schema, even when it is stale.
	if f, err := os.Open(name); err == nil {
		raw, _ := io.ReadAll(io.LimitReader(f, (1<<20)+1))
		f.Close()
		var header struct {
			Version int `json:"version"`
		}
		if json.Unmarshal(raw, &header) == nil && header.Version != 0 && header.Version != 1 {
			return errors.New("unsupported strategy cache version")
		}
	}
	if len(value.Fingerprint) != 64 || strings.Trim(value.Fingerprint, "0123456789abcdef") != "" || value.Strategy == "" || value.CheckedAt.IsZero() || value.Failures < 0 || value.NextIndex < 0 || value.NextIndex > 4096 {
		return errors.New("invalid strategy cache contents")
	}
	value.Version = 1
	value.CheckedAt = value.CheckedAt.UTC()
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(raw) > 1<<20 {
		return errors.New("strategy cache exceeds limit")
	}
	if err = os.MkdirAll(filepath.Dir(name), 0700); err != nil {
		return err
	}
	if err = writePrivate(name, raw); err != nil {
		return err
	}
	entries, err := os.ReadDir(filepath.Dir(name))
	if err != nil {
		return nil
	}
	type candidate struct {
		name     string
		modified time.Time
	}
	candidates := []candidate{}
	for _, entry := range entries {
		scope, ok := strings.CutPrefix(entry.Name(), "strategy-cache-")
		if !ok || entry.IsDir() {
			continue
		}
		scope, ok = strings.CutSuffix(scope, ".json")
		if !ok || !scopeName.MatchString(scope) {
			continue
		}
		candidateName := filepath.Join(filepath.Dir(name), entry.Name())
		if f, err := os.Open(candidateName); err == nil {
			header := struct {
				Version int `json:"version"`
			}{}
			raw, _ := io.ReadAll(io.LimitReader(f, (1<<20)+1))
			f.Close()
			if json.Unmarshal(raw, &header) == nil && header.Version != 0 && header.Version != 1 {
				continue
			}
		}
		info, err := entry.Info()
		if err == nil {
			candidates = append(candidates, candidate{filepath.Join(filepath.Dir(name), entry.Name()), info.ModTime()})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].modified.Equal(candidates[j].modified) {
			return candidates[i].name < candidates[j].name
		}
		return candidates[i].modified.Before(candidates[j].modified)
	})
	for _, candidate := range candidates {
		if len(candidates) <= 16 {
			break
		}
		if candidate.name == name {
			continue
		}
		if os.Remove(candidate.name) == nil {
			candidates = candidates[1:]
		}
	}
	return nil
}
