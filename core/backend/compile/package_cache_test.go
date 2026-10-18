package compile

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestPackageListsReuseLegacyCacheOfflineAndRefreshValidatedContent(t *testing.T) {
	var requests atomic.Int32
	var body atomic.Value
	body.Store("com.updated.app\n")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		_, _ = w.Write([]byte(body.Load().(string)))
	}))
	defer server.Close()
	cache := &PackageListCache{ProfilesDir: t.TempDir(), Client: server.Client()}
	legacy, _ := cache.path("legacy", server.URL)
	if err := savePackageList(legacy, "com.saved.app\n"); err != nil {
		t.Fatal(err)
	}
	// The source validator must not download again under its temporary ID.
	got, err := cache.Read(context.Background(), "validation", server.URL)
	if err != nil || got != "com.saved.app\n" || requests.Load() != 0 {
		t.Fatal("cache read waited for the network", got, err, requests.Load())
	}
	cache.Refresh(context.Background())
	got, err = cache.Read(context.Background(), "validation", server.URL)
	if err != nil || got != "com.updated.app\n" || requests.Load() != 1 {
		t.Fatal("background refresh not applied", got, err, requests.Load())
	}
	// An invalid replacement must never poison the working package policy.
	body.Store("re:(\n")
	cache.Reset()
	_, _ = cache.Read(context.Background(), "validation", server.URL)
	cache.Refresh(context.Background())
	got, err = cache.Read(context.Background(), "validation", server.URL)
	if err != nil || got != "com.updated.app\n" {
		t.Fatal("invalid refresh poisoned the cache", got, err)
	}
	server.Close()
	cache.Reset()
	got, err = cache.Read(context.Background(), "validation", server.URL)
	if err != nil || got != "com.updated.app\n" {
		t.Fatal("offline restart lost package policy", got, err)
	}
	cache.Refresh(context.Background())
	got, err = cache.Read(context.Background(), "validation", server.URL)
	if err != nil || got != "com.updated.app\n" {
		t.Fatal("failed refresh removed cached policy", got, err)
	}
}

func TestPackageListFirstDownloadIsCachedPrivately(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("com.example.app\n")) }))
	defer server.Close()
	cache := &PackageListCache{ProfilesDir: t.TempDir(), Client: server.Client()}
	if _, err := cache.Read(context.Background(), "p", server.URL); err != nil {
		t.Fatal(err)
	}
	name, _ := cache.path("p", server.URL)
	info, err := os.Stat(name)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("cache is not private", info, err)
	}
	if filepath.Base(name) != md5Text(server.URL) {
		t.Fatal("legacy cache identity changed")
	}
}

func TestResetFencesLatePackageListRefresh(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
	}))
	defer server.Close()
	cache := &PackageListCache{ProfilesDir: t.TempDir(), Client: server.Client()}
	name, _ := cache.path("p", server.URL)
	if err := savePackageList(name, "com.example.app"); err != nil {
		t.Fatal(err)
	}
	_, _ = cache.Read(context.Background(), "p", server.URL)
	done := make(chan struct{})
	go func() { cache.Refresh(context.Background()); close(done) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("refresh did not start")
	}
	cache.Reset()
	if err := os.RemoveAll(cache.ProfilesDir); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("reset did not cancel background refresh")
	}
	if _, err := os.Stat(name); !os.IsNotExist(err) {
		t.Fatal("late cache write survived data erasure", err)
	}
}
