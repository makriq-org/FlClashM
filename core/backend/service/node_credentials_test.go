package service

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestNodeServiceKeySurvivesConcurrentOpen(t *testing.T) {
	directory := t.TempDir()
	var keys [4][32]byte
	var workers sync.WaitGroup
	for i := range keys {
		workers.Go(func() {
			key, err := loadNodeServiceKey(directory)
			if err != nil {
				t.Error(err)
			}
			keys[i] = key
		})
	}
	workers.Wait()
	reopened, err := loadNodeServiceKey(directory)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range keys {
		if key == ([32]byte{}) || key != reopened {
			t.Fatal("concurrent opens did not use the persisted key")
		}
	}
	info, err := os.Stat(filepath.Join(directory, "node-service.key"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatal("node service key must be private")
	}
}

func TestCorruptNodeServiceKeyIsRegenerated(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "node-service.key")
	for _, size := range []int{0, 32, 128} {
		if err := os.WriteFile(path, make([]byte, size), 0600); err != nil {
			t.Fatal(err)
		}
		key, err := loadNodeServiceKey(directory)
		if err != nil || key == ([32]byte{}) {
			t.Fatal("could not replace corrupt service key", err)
		}
		reopened, err := loadNodeServiceKey(directory)
		if err != nil || reopened != key {
			t.Fatal("replacement service key was not persisted", err)
		}
	}
}
