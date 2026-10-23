package transport

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"core/backend"
)

func TestStrategyCacheMigrationScopesAndVersion(t *testing.T) {
	store := &CacheStore{Home: t.TempDir(), ABI: "host", LegacyTimeZone: time.FixedZone("legacy", 3*60*60)}
	id := "byedpi-" + strings.Repeat("a", 32)
	name, err := store.path(id, "network-a")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.MkdirAll(filepath.Dir(name), 0700); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(filepath.Dir(name), "strategy-cache.json")
	source := `{"fingerprint":"` + strings.Repeat("b", 64) + `","strategy":"-d1","checkedAt":"2026-10-18T15:00:00.000","failures":0,"selectionRevision":2,"verified":true,"nextIndex":0}`
	if err = os.WriteFile(legacy, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	value, err := store.Read(context.Background(), id, "network-a")
	if err != nil || !value.Verified || value.CheckedAt.Hour() != 12 || value.CheckedAt.Location() != time.UTC {
		t.Fatalf("legacy cache timezone: %#v %v", value, err)
	}
	if _, err = os.Stat(legacy); !os.IsNotExist(err) {
		t.Fatal("legacy cache remained authoritative", err)
	}
	value.Strategy = "-s2"
	if err = store.Write(context.Background(), id, "network-b", value); err != nil {
		t.Fatal(err)
	}
	original, err := store.Read(context.Background(), id, "network-a")
	if err != nil || original.Strategy != "-d1" {
		t.Fatal("network caches mixed", original, err)
	}
	for i := range 20 {
		if err = store.Write(context.Background(), id, fmt.Sprintf("network-%02d", i), value); err != nil {
			t.Fatal(err)
		}
	}
	entries, _ := os.ReadDir(filepath.Dir(name))
	if len(entries) > 16 {
		t.Fatal("unbounded network caches", len(entries))
	}
	future, _ := store.path(id, "future")
	unknown := []byte(`{"version":99}`)
	if err = os.WriteFile(future, unknown, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = store.Read(context.Background(), id, "future"); err == nil {
		t.Fatal("future cache accepted")
	}
	if err = store.Write(context.Background(), id, "future", value); err == nil {
		t.Fatal("future cache overwritten")
	}
	raw, _ := os.ReadFile(future)
	if string(raw) != string(unknown) {
		t.Fatal("future cache changed")
	}
	if err = store.Write(context.Background(), id, "../../outside", value); err == nil {
		t.Fatal("scope escaped cache directory")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err = store.Write(ctx, id, "cancelled", backend.StrategyCache{}); err == nil {
		t.Fatal("cancelled cache write accepted")
	}
}
