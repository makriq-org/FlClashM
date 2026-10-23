package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func validator(ctx context.Context, source string) error {
	if !strings.Contains(source, "proxies:") {
		return errors.New("invalid profile")
	}
	return ctx.Err()
}
func openRepository(t *testing.T) *Repository {
	t.Helper()
	r, err := Open(t.TempDir(), validator)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
func metadata(id, address string) Object {
	return Object{"id": mustJSON(id), "url": mustJSON(address), "autoUpdate": mustJSON(true), "autoUpdateDuration": mustJSON(int64(time.Hour / time.Microsecond)), "opaque": json.RawMessage(`{"integer":9007199254740993}`)}
}
func create(t *testing.T, r *Repository, id, address string) Record {
	t.Helper()
	p, err := r.Put(context.Background(), metadata(id, address), "proxies: []\n", 0)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestDirectorySyncFailureAfterRenameKeepsCatalogWritable(t *testing.T) {
	r := openRepository(t)
	syncs := 0
	r.syncDirectory = func(string) error {
		syncs++
		return errors.New("injected directory sync failure")
	}
	first := create(t, r, "one", "")
	if _, err := r.Put(context.Background(), metadata("one", ""), "proxies: []\n# updated\n", first.Revision); err != nil {
		t.Fatal("committed rename left the catalog unwritable", err)
	}
	reopened, err := Open(filepath.Dir(r.path), validator)
	if err != nil {
		t.Fatal(err)
	}
	if syncs != 2 || !reflect.DeepEqual(r.Snapshot(), reopened.Snapshot()) {
		t.Fatal("memory and renamed catalog disagree", syncs, r.Snapshot(), reopened.Snapshot())
	}
}
func TestLegacyMigrationAndRoundTripPreserveSourceAndUnknownSettings(t *testing.T) {
	directory := t.TempDir()
	r, err := Open(directory, validator)
	if err != nil {
		t.Fatal(err)
	}
	settings := []byte(`{"profiles":[{"id":"one","opaque":9007199254740993}],"currentProfileId":"one","unknown":{"value":9007199254740993},"patchClashConfig":{"mixed-port":4321}}`)
	source := "# comment\nbase: &base {type: socks5, server: example.test}\nproxies: [{<<: *base, name: server}]\n"
	reads := 0
	read := func(id string) (string, error) { reads++; return source, nil }
	if err = r.Migrate(context.Background(), settings, read); err != nil {
		t.Fatal(err)
	}
	if err = r.Migrate(context.Background(), []byte(`{}`), read); err != nil {
		t.Fatal(err)
	}
	if reads != 1 {
		t.Fatal("migration repeated source reads")
	}
	p, err := r.Get("one")
	if err != nil || p.Source != source {
		t.Fatalf("source lost: %+v %v", p, err)
	}
	exported, err := r.ExportLegacy()
	if err != nil {
		t.Fatal(err)
	}
	var actual, want Object
	_ = json.Unmarshal(exported, &actual)
	_ = json.Unmarshal(settings, &want)
	if !reflect.DeepEqual(actual, want) {
		t.Fatalf("changed legacy settings: %s", exported)
	}
	reopened, err := Open(directory, validator)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(r.Snapshot(), reopened.Snapshot()) {
		t.Fatal("reopen changed migration")
	}
	snapshot := r.Snapshot()
	snapshot.Profiles[0].Metadata["opaque"][0] = 'x'
	original, _ := r.Get("one")
	if !json.Valid(original.Metadata["opaque"]) {
		t.Fatal("snapshot mutated store")
	}
}
func TestMigrationFailureAndMissingCache(t *testing.T) {
	r := openRepository(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	original := r.Snapshot()
	if err := r.Migrate(ctx, []byte(`{"profiles":[{"id":"one"}]}`), func(string) (string, error) { return "proxies: []", nil }); err == nil || !reflect.DeepEqual(original, r.Snapshot()) {
		t.Fatal("cancelled migration committed")
	}
	if err := r.Migrate(context.Background(), []byte(`{"profiles":[{"id":"one","url":"https://example.test/sub"}]}`), func(string) (string, error) { return "", os.ErrNotExist }); err != nil {
		t.Fatal(err)
	}
	p, err := r.Get("one")
	if err != nil || p.Source != "" || !p.SourceMissing {
		t.Fatalf("missing cached subscription lost: %+v %v", p, err)
	}
}

func TestMigrationKeepsOtherProfilesWhenOneLegacyRecordIsBad(t *testing.T) {
	directory := t.TempDir()
	legacy := filepath.Join(directory, "legacy")
	if err := os.MkdirAll(legacy, 0700); err != nil {
		t.Fatal(err)
	}
	// The old Flutter importer accepted files up to 20 MiB.
	if err := os.WriteFile(filepath.Join(legacy, "large.yaml"), []byte("proxies: []\n"+strings.Repeat("#", MaxProfileBytes)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "good.yaml"), []byte("proxies: []\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "dup.yaml"), []byte("proxies: []\n# first\n"), 0600); err != nil {
		t.Fatal(err)
	}
	r, err := Open(filepath.Join(directory, "store"), validator)
	if err != nil {
		t.Fatal(err)
	}
	settings := []byte(`{"currentProfileId":"good","profiles":[` +
		`{"id":"large","label":"Large","url":"https://example.test/large"},` +
		`{"id":"broken","label":"Broken"},` +
		`{"id":"../escape","label":"Unsafe"},` +
		`{"id":7},` +
		`"not an object",` +
		`{"id":"dup","label":"First"},` +
		`{"id":"dup","label":"Second"},` +
		`{"id":"good","label":"Good"}]}`)
	failRead := true
	read := func(id string) (string, error) {
		if id == "broken" && failRead {
			return "", errors.New("injected read failure")
		}
		return ReadLegacySource(legacy, id)
	}
	// A read error that may be transient must not commit the migration without
	// the profile content: the next start retries it.
	if err = r.Migrate(context.Background(), settings, read); err == nil || r.Snapshot().Migrated {
		t.Fatal("transient read failure committed the migration", err)
	}
	failRead = false
	if err = r.Migrate(context.Background(), settings, read); err != nil {
		t.Fatal("one bad legacy profile blocked migration:", err)
	}
	snapshot := r.Snapshot()
	if !snapshot.Migrated {
		t.Fatal("migration marker was not written")
	}
	var ids []string
	for _, record := range snapshot.Profiles {
		id, _ := profileID(record.Metadata)
		ids = append(ids, id)
	}
	if !reflect.DeepEqual(ids, []string{"large", "broken", "dup", "good"}) {
		t.Fatal("unexpected migrated profiles", ids)
	}
	for _, id := range []string{"large", "broken"} {
		record, err := r.Get(id)
		if err != nil || !record.SourceMissing || record.Source != "" {
			t.Fatalf("absent or oversized source %s was not kept as missing: %+v %v", id, record, err)
		}
	}
	large, _ := r.Get("large")
	if string(large.Metadata["label"]) != `"Large"` || string(large.Metadata["url"]) != `"https://example.test/large"` {
		t.Fatal("metadata of an oversized profile was lost", large.Metadata)
	}
	dup, _ := r.Get("dup")
	if string(dup.Metadata["label"]) != `"First"` || dup.Source != "proxies: []\n# first\n" {
		t.Fatal("duplicate legacy id replaced the first record", dup.Metadata)
	}
	good, _ := r.Get("good")
	if good.SourceMissing || good.Source != "proxies: []\n" || string(snapshot.Settings["currentProfileId"]) != `"good"` {
		t.Fatal("valid profile changed during resilient migration", good)
	}
	if _, err = Open(filepath.Join(directory, "store"), validator); err != nil {
		t.Fatal("migrated store cannot be reopened:", err)
	}
}

func TestMigrationTreatsUndecodableLegacySettingsAsEmpty(t *testing.T) {
	for _, raw := range []string{`{"profiles":`, `[]`, `null`, `"text"`, `{"profiles":{"id":"one"},"appSetting":{"locale":"ru"}}`} {
		t.Run(raw, func(t *testing.T) {
			r := openRepository(t)
			if err := r.Migrate(context.Background(), []byte(raw), func(string) (string, error) { return "proxies: []", nil }); err != nil {
				t.Fatal("invalid legacy settings blocked migration:", err)
			}
			snapshot := r.Snapshot()
			if !snapshot.Migrated || len(snapshot.Profiles) != 0 {
				t.Fatal("invalid legacy settings were not replaced by a fresh state", snapshot)
			}
			if _, exists := snapshot.Settings["profiles"]; exists {
				t.Fatal("legacy profile list leaked into settings")
			}
		})
	}
}
func TestRevisionGuardsDeletionAndCancellation(t *testing.T) {
	r := openRepository(t)
	p := create(t, r, "one", "")
	newer, err := r.Put(context.Background(), p.Metadata, "proxies: []\n# edited", p.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = r.Put(context.Background(), p.Metadata, "proxies: []\n# stale", p.Revision); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	if err = r.Delete("one", p.Revision); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	if err = r.Delete("one", newer.Revision); err != nil {
		t.Fatal(err)
	}
	recreated := create(t, r, "one", "")
	if recreated.Revision <= newer.Revision {
		t.Fatal("reused profile revision")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = r.Put(ctx, recreated.Metadata, "proxies: []\n# cancelled", recreated.Revision); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	current, _ := r.Get("one")
	if current.Revision != recreated.Revision {
		t.Fatal("cancelled write committed")
	}
}
func TestUnsupportedStoreAndUnsafeLegacyPathsFailClosed(t *testing.T) {
	directory := t.TempDir()
	raw := []byte(`{"version":99}`)
	if err := os.WriteFile(filepath.Join(directory, "profiles.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(directory, validator); err == nil {
		t.Fatal("accepted future schema")
	}
	actual, _ := os.ReadFile(filepath.Join(directory, "profiles.json"))
	if string(actual) != string(raw) {
		t.Fatal("overwrote future schema")
	}
	for _, id := range []string{"../secret", "a/b", "a\\b", "..", ""} {
		if _, err := ReadLegacySource(directory, id); err == nil {
			t.Fatalf("accepted unsafe id %q", id)
		}
	}
}
func TestSubscriptionMetadataHeadersAndNoDeviceHeaders(t *testing.T) {
	var lock sync.Mutex
	var received []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lock.Lock()
		received = append(received, r.Header.Get("X-Hwid"))
		lock.Unlock()
		w.Header().Set("flclashm-androidsecure", "true")
		w.Header().Set("profile-update-interval", "6")
		w.Header().Set("subscription-userinfo", "upload=10; download=20; total=100; expire=200")
		w.Header().Set("Content-Disposition", `attachment; filename="subscription.yaml"`)
		_, _ = w.Write([]byte("proxies: []\n# downloaded"))
	}))
	defer server.Close()
	r := openRepository(t)
	profile := create(t, r, "one", server.URL)
	profile.Metadata["providerHeaders"] = mustJSON(map[string]string{"flclashx-androidsecure": "false", "flclashm-servicename": "remember", "announce": "stale", "support-url": "stale", "x-hwid-not-supported": "true"})
	if _, err := r.Put(context.Background(), profile.Metadata, profile.Source, profile.Revision); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 18, 10, 0, 0, 0, time.UTC)
	service := &Subscriptions{Repository: r, Client: server.Client(), Now: func() time.Time { return now }, DeviceHeaders: func(context.Context) (map[string]string, error) { return map[string]string{"X-Hwid": "device"}, nil }}
	updated, err := service.Update(context.Background(), "one", false)
	if err != nil {
		t.Fatal(err)
	}
	var headers map[string]string
	_ = json.Unmarshal(updated.Metadata["providerHeaders"], &headers)
	if headers["flclashm-androidsecure"] != "true" || headers["flclashx-androidsecure"] != "" || headers["flclashm-servicename"] != "remember" || headers["announce"] != "" || headers["support-url"] != "" || headers["x-hwid-not-supported"] != "" {
		t.Fatal(headers)
	}
	if string(updated.Metadata["autoUpdateDuration"]) != "21600000000" {
		t.Fatal(string(updated.Metadata["autoUpdateDuration"]))
	}
	if string(updated.Metadata["label"]) != `"subscription.yaml"` || !strings.Contains(string(updated.Metadata["subscriptionInfo"]), `"download":20`) {
		t.Fatal(updated.Metadata)
	}
	if ids := service.Due(now.Add(6 * time.Hour)); len(ids) != 0 {
		t.Fatal(ids)
	}
	if ids := service.Due(now.Add(6*time.Hour + time.Microsecond)); !reflect.DeepEqual(ids, []string{"one"}) {
		t.Fatal(ids)
	}
	if _, err = service.Update(context.Background(), "one", true); err != nil {
		t.Fatal(err)
	}
	lock.Lock()
	defer lock.Unlock()
	if !reflect.DeepEqual(received, []string{"", "device"}) {
		t.Fatal(received)
	}
}
func TestLateSubscriptionResponseCannotOverwriteEditor(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		_, _ = w.Write([]byte("proxies: []\n# late response"))
	}))
	defer server.Close()
	repository := openRepository(t)
	profile := create(t, repository, "one", server.URL)
	service := &Subscriptions{Repository: repository, Client: server.Client()}
	done := make(chan error, 1)
	go func() { _, err := service.Update(context.Background(), "one", false); done <- err }()
	<-entered
	edited, err := repository.Put(context.Background(), profile.Metadata, "proxies: []\n# editor", profile.Revision)
	if err != nil {
		t.Fatal(err)
	}
	close(release)
	if err = <-done; !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	current, _ := repository.Get("one")
	if !reflect.DeepEqual(current, edited) {
		t.Fatal("late response replaced editor data")
	}
}
func TestFailedSubscriptionNeverReplacesCommittedProfile(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		body   string
	}{{"http", 500, "failure"}, {"invalid", 200, "invalid source"}} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			repository := openRepository(t)
			original := create(t, repository, "one", server.URL)
			service := &Subscriptions{Repository: repository, Client: server.Client()}
			if _, err := service.Update(context.Background(), "one", false); err == nil {
				t.Fatal("accepted failed update")
			}
			current, _ := repository.Get("one")
			if !reflect.DeepEqual(current, original) {
				t.Fatal("failed update changed committed profile")
			}
		})
	}
}

func TestUIProjectionsCannotEraseUnknownFields(t *testing.T) {
	r := openRepository(t)
	state := r.Snapshot()
	if err := r.UpdateSettings(Object{"unknown": mustJSON("keep"), "appSetting": json.RawMessage(`{"testUrl":"https://example.test","future":true}`)}, state.Revision); err != nil {
		t.Fatal(err)
	}
	state = r.Snapshot()
	if err := r.UpdateSettings(Object{"appSetting": json.RawMessage(`{"testUrl":"https://changed.test"}`)}, state.Revision); err != nil {
		t.Fatal(err)
	}
	state = r.Snapshot()
	if string(state.Settings["unknown"]) != `"keep"` || !strings.Contains(string(state.Settings["appSetting"]), `"future":true`) {
		t.Fatal(state.Settings)
	}
	original := create(t, r, "one", "")
	updated, err := r.Put(context.Background(), Object{"id": mustJSON("one"), "label": mustJSON("edited")}, original.Source, original.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if string(updated.Metadata["opaque"]) != `{"integer":9007199254740993}` {
		t.Fatal(string(updated.Metadata["opaque"]))
	}
}

func TestDictionaryReplacementRetainsUserDeletions(t *testing.T) {
	r := openRepository(t)
	state := r.Snapshot()
	if err := r.UpdateSettings(Object{"patchClashConfig": json.RawMessage(`{"hosts":{"first":"1.1.1.1","removed":"2.2.2.2"},"future":true}`)}, state.Revision); err != nil {
		t.Fatal(err)
	}
	state = r.Snapshot()
	if err := r.UpdateSettings(Object{"patchClashConfig": json.RawMessage(`{"hosts":{"first":"1.1.1.1"}}`)}, state.Revision); err != nil {
		t.Fatal(err)
	}
	state = r.Snapshot()
	if strings.Contains(string(state.Settings["patchClashConfig"]), "removed") || !strings.Contains(string(state.Settings["patchClashConfig"]), `"future":true`) {
		t.Fatal(string(state.Settings["patchClashConfig"]))
	}
}

func TestHeadlessSubscriptionScheduleUsesInjectedTicks(t *testing.T) {
	now := time.Date(2026, 10, 18, 10, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("proxies: []\n# scheduled")) }))
	defer server.Close()
	repository := openRepository(t)
	create(t, repository, "one", server.URL)
	updated := make(chan string, 1)
	service := &Subscriptions{Repository: repository, Client: server.Client(), Now: func() time.Time { return now }, OnUpdated: func(ctx context.Context, id string, revision uint64) error { updated <- id; return nil }}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ticks := make(chan time.Time, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		service.Run(ctx, ticks, func(id string, err error) { t.Errorf("scheduled update: %v", err) })
	}()
	ticks <- now
	select {
	case id := <-updated:
		if id != "one" {
			t.Fatal(id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("headless schedule did not run")
	}
	if due := service.Due(now.Add(time.Minute)); len(due) != 0 {
		t.Fatal("updated subscription remained due")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("scheduler ignored cancellation")
	}
}

func TestCancelledSubscriptionPreservesCommittedProfile(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() }))
	defer server.Close()
	repository := openRepository(t)
	old := create(t, repository, "one", server.URL)
	service := &Subscriptions{Repository: repository, Client: server.Client()}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := service.Update(ctx, "one", false); done <- err }()
	<-entered
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("subscription ignored cancellation")
	}
	current, _ := repository.Get("one")
	if !reflect.DeepEqual(current, old) {
		t.Fatal("cancelled subscription was committed")
	}
}

func TestSourceIntegrityAndSharedSourceDeletion(t *testing.T) {
	r := openRepository(t)
	one := create(t, r, "one", "")
	two := create(t, r, "two", "")
	if err := r.Delete("one", one.Revision); err != nil {
		t.Fatal(err)
	}
	if got, err := r.Get("two"); err != nil || got.Source != two.Source {
		t.Fatalf("shared source was removed: %+v %v", got, err)
	}
	if err := os.WriteFile(r.sourcePath(two.Digest), []byte("proxies: []\n# tampered"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get("two"); err == nil {
		t.Fatal("returned an altered source for a committed digest")
	}
}

func TestMigrationRetainsOriginalBytesOfBrokenLegacySource(t *testing.T) {
	r := openRepository(t)
	source := string([]byte{'#', 0xff, '\n'})
	if err := r.Migrate(context.Background(), []byte(`{"profiles":[{"id":"broken"}]}`), func(string) (string, error) { return source, nil }); err != nil {
		t.Fatal(err)
	}
	got, err := r.Get("broken")
	if err != nil || got.Source != source {
		t.Fatal("migration changed original bytes")
	}
	reopened, err := Open(filepath.Dir(r.path), validator)
	if err != nil {
		t.Fatal(err)
	}
	got, err = reopened.Get("broken")
	if err != nil || got.Source != source {
		t.Fatal("reopen changed original bytes")
	}
}

func TestSubscriptionReplacementHostRetainsCredentialsPathAndQuery(t *testing.T) {
	for _, replacement := range []string{"new.example.test", "2001:4860:4860::8888"} {
		t.Run(replacement, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				user, password, ok := r.BasicAuth()
				if !ok || user != "user" || password != "password" {
					t.Error("subscription credentials were lost")
				}
				w.Header().Set("flclashm-newdomain", replacement)
				w.Header().Set("flclashx-newdomain", "stale.example.test")
				_, _ = w.Write([]byte("proxies: []"))
			}))
			defer server.Close()
			address := strings.Replace(server.URL, "http://", "http://user:password@", 1) + "/subscription?token=keep"
			repository := openRepository(t)
			create(t, repository, "one", address)
			service := &Subscriptions{Repository: repository, Client: server.Client()}
			updated, err := service.Update(context.Background(), "one", false)
			if err != nil {
				t.Fatal(err)
			}
			var stored string
			_ = json.Unmarshal(updated.Metadata["url"], &stored)
			parsed, err := url.Parse(stored)
			if err != nil || parsed.Hostname() != replacement || parsed.Path != "/subscription" || parsed.RawQuery != "token=keep" || parsed.User.Username() != "user" {
				t.Fatalf("incorrect replacement URL: %q %v", stored, err)
			}
		})
	}
}

func TestSubscriptionExplicitEmptyUserAgent(t *testing.T) {
	received := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received <- r.Header.Get("User-Agent")
		_, _ = w.Write([]byte("proxies: []\n"))
	}))
	defer server.Close()
	repository := openRepository(t)
	create(t, repository, "one", server.URL)
	err := repository.UpdateSettings(Object{"patchClashConfig": mustJSON(map[string]any{"global-ua": ""})}, repository.Snapshot().Revision)
	if err != nil {
		t.Fatal(err)
	}
	service := Subscriptions{Repository: repository, Client: server.Client(), UserAgent: "Default/version"}
	if _, err = service.Update(context.Background(), "one", false); err != nil {
		t.Fatal(err)
	}
	if got := <-received; got != "" {
		t.Fatal("explicit empty override replaced with default", got)
	}
}

func TestSubscriptionLegacyLocalUpdateDateKeepsSchedule(t *testing.T) {
	repository := openRepository(t)
	profile := create(t, repository, "one", "https://example.com/profile")
	profile.Metadata["autoUpdate"] = mustJSON(true)
	profile.Metadata["autoUpdateDuration"] = mustJSON(int64(time.Hour / time.Microsecond))
	profile.Metadata["lastUpdateDate"] = mustJSON("2026-10-18T15:00:00.000")
	if _, err := repository.Put(context.Background(), profile.Metadata, profile.Source, profile.Revision); err != nil {
		t.Fatal(err)
	}
	service := Subscriptions{Repository: repository, LegacyTimeZone: time.FixedZone("legacy", 3*60*60)}
	if due := service.Due(time.Date(2026, 10, 18, 12, 30, 0, 0, time.UTC)); len(due) != 0 {
		t.Fatal("legacy local timestamp caused early update", due)
	}
	if due := service.Due(time.Date(2026, 10, 18, 13, 0, 0, 1000, time.UTC)); len(due) != 1 {
		t.Fatal("legacy due update missed", due)
	}
}

func TestEmptyProviderHeaderClearsThePreviousNamespaceValue(t *testing.T) {
	headers := collectProviderHeaders(http.Header{"Flclashm-Androidsecure": []string{""}, "Announce": []string{""}})
	merged := MergeProviderHeaders(map[string]string{"flclashx-androidsecure": "true", "announce": "old"}, headers)
	value, present := merged["flclashm-androidsecure"]
	if !present || value != "" {
		t.Fatal("explicit empty provider setting was lost", merged)
	}
	if _, exists := merged["flclashx-androidsecure"]; exists {
		t.Fatal("old namespace survived replacement", merged)
	}
	if _, exists := merged["announce"]; exists {
		t.Fatal("empty volatile notice was retained", merged)
	}
}
