package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestProviderResourceCannotReadAuthorityOrEscapeCache(t *testing.T) {
	home := t.TempDir()
	cache := filepath.Join(home, "profiles", "providers")
	if err := os.MkdirAll(cache, 0700); err != nil {
		t.Fatal(err)
	}
	valid := filepath.Join(cache, "rules")
	if err := os.WriteFile(valid, []byte("example.org\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if data, err := readTrustedProviderCache(context.Background(), home, valid); err != nil || string(data) != "example.org\n" {
		t.Fatal("valid cache unreadable", err)
	}
	authority := filepath.Join(home, "catalog.json")
	if err := os.WriteFile(authority, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(authority, filepath.Join(cache, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{authority, filepath.Join(cache, "..", "..", "catalog.json"), filepath.Join(cache, "escape"), cache} {
		if _, err := readTrustedProviderCache(context.Background(), home, path); err == nil {
			t.Errorf("read escaped through %s", path)
		}
	}
}

func TestProviderResourceRejectsOversizeAndCancelledRead(t *testing.T) {
	home := t.TempDir()
	cache := filepath.Join(home, "providers")
	if err := os.MkdirAll(cache, 0700); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(filepath.Join(cache, "large"))
	if err != nil {
		t.Fatal(err)
	}
	if err = file.Truncate(16<<20 + 1); err != nil {
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = readTrustedProviderCache(context.Background(), home, file.Name()); err == nil {
		t.Fatal("oversized resource was read")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = readTrustedProviderCache(ctx, home, file.Name()); err != context.Canceled {
		t.Fatal("cancelled read", err)
	}
}
