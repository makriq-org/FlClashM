package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"github.com/metacubex/bbolt"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
)

// Called only inside the coordinator effect queue. Immutable RuntimePlans and
// provider files can still be referenced by recovery, so never unlink those.
// Compilation itself is fresh on every request; there is no mutable per-profile
// compiled-config cache to invalidate. A profile clear also flushes observations
// which could otherwise mask its next compilation/lookup.
func clearBackendCache(ctx context.Context, raw json.RawMessage) error {
	var params struct {
		ProfileID string `json:"profileId"`
	}
	if err := decodeDiagnosticParams(raw, &params); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	resolver.ClearCache()
	geodata.ClearGeoIPCache()
	geodata.ClearGeoSiteCache()
	return clearTransientCache(cachefile.Cache().DB)
}

func clearTransientCache(db *bbolt.DB) error {
	if db == nil {
		return nil
	}
	return db.Update(func(tx *bbolt.Tx) error {
		// Selected proxies and fake-IP allocations remain valid live state.
		for _, name := range []string{"etag", "subscriptioninfo", "storage"} {
			if err := tx.DeleteBucket([]byte(name)); err != nil && !errors.Is(err, bbolt.ErrBucketNotFound) {
				return err
			}
		}
		return nil
	})
}

func collectBackendCache(ctx context.Context, raw json.RawMessage) error {
	if err := decodeDiagnosticParams(raw, &struct{}{}); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// The pre-Bolt cache has a fixed trusted name and no current readers.
	// Source-blob reachability collection is performed by the Go repository.
	// Unknown files and all plan/provider/node artifacts remain pinned.
	return removeObsoleteCache(constant.Path.OldCache())
}

func removeObsoleteCache(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	return os.Remove(path)
}
