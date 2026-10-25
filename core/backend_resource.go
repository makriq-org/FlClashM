package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"

	proxyprovider "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	ruleprovider "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

// A UI resource name is resolved against the current engine namespace. The UI
// never supplies a platform path, and the catalog/journal are outside this
// reader's filesystem capabilities.
func readBackendProviderResource(ctx context.Context, name, kind string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	runLock.Lock()
	var provider cp.Provider
	switch kind {
	case "proxy":
		provider = tunnel.Providers()[name]
	case "rule":
		provider = tunnel.RuleProviders()[name]
	default:
		runLock.Unlock()
		return nil, errors.New("unsupported provider type")
	}
	if provider == nil || provider.VehicleType() == cp.Compatible || provider.VehicleType() == cp.Inline {
		runLock.Unlock()
		return nil, errors.New("provider has no cached resource")
	}
	var path string
	switch provider := provider.(type) {
	case *proxyprovider.ProxySetProvider:
		path = provider.Vehicle().Path()
	case *ruleprovider.RuleSetProvider:
		path = provider.Vehicle().Path()
	}
	home := constant.Path.HomeDir()
	runLock.Unlock()
	if path == "" {
		return nil, errors.New("provider has no cached resource")
	}
	return readTrustedProviderCache(ctx, home, path)
}

func readTrustedProviderCache(ctx context.Context, home, path string) ([]byte, error) {
	const maxBytes = 16 << 20
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(home, path)
	}
	// New compiler caches and pre-migration caches have separate trusted roots.
	for _, directory := range []string{filepath.Join(home, "profiles", "providers"), filepath.Join(home, "providers")} {
		relative, err := filepath.Rel(directory, path)
		if err != nil || !filepath.IsLocal(relative) {
			continue
		}
		root, err := os.OpenRoot(directory)
		if err != nil {
			return nil, err
		}
		defer root.Close()
		file, err := root.Open(relative)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() > maxBytes {
			return nil, errors.New("provider resource is not a bounded regular file")
		}
		data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
		if err != nil {
			return nil, err
		}
		if len(data) > maxBytes {
			return nil, errors.New("provider resource exceeds size limit")
		}
		return data, ctx.Err()
	}
	return nil, errors.New("provider resource is outside the trusted cache")
}
