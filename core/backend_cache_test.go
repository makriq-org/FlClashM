package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/bbolt"
)

func TestClearCachePreservesLiveSelectionsAndFakeIP(t *testing.T) {
	db, err := bbolt.Open(filepath.Join(t.TempDir(), "cache.db"), 0600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = db.Update(func(tx *bbolt.Tx) error {
		for _, name := range []string{"selected", "fakeip", "fakeip6", "etag", "subscriptioninfo", "storage", "unknown"} {
			b, err := tx.CreateBucket([]byte(name))
			if err != nil {
				return err
			}
			if err := b.Put([]byte("key"), []byte("value")); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err = clearTransientCache(db); err != nil {
		t.Fatal(err)
	}
	if err = db.View(func(tx *bbolt.Tx) error {
		for _, name := range []string{"selected", "fakeip", "fakeip6", "unknown"} {
			if b := tx.Bucket([]byte(name)); b == nil || string(b.Get([]byte("key"))) != "value" {
				t.Errorf("live bucket %s was changed", name)
			}
		}
		for _, name := range []string{"etag", "subscriptioninfo", "storage"} {
			if tx.Bucket([]byte(name)) != nil {
				t.Errorf("cache bucket %s survived", name)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestCollectCachePreservesDirectoriesAndSymlinkTargets(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "profile.yaml")
	if err := os.WriteFile(target, []byte("source"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, ".cache")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := removeObsoleteCache(link); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(link); err != nil {
		t.Fatal("symlink was removed", err)
	}
	if err := removeObsoleteCache(dir); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "source" {
		t.Fatal("profile was changed", err)
	}
	if err := removeObsoleteCache(target); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatal("obsolete file survived", err)
	}
}
