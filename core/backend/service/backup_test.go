package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func upload(t *testing.T, app *App, data []byte) Blob {
	t.Helper()
	blob, err := app.newBlob()
	if err != nil {
		t.Fatal(err)
	}
	for offset := 0; offset < len(data); {
		end := min(offset+blobChunkBytes, len(data))
		blob, err = app.appendBlob(context.Background(), blob.Token, int64(offset), base64.StdEncoding.EncodeToString(data[offset:end]))
		if err != nil {
			t.Fatal(err)
		}
		offset = end
	}
	return blob
}

func TestProfileExportPreservesLegacyBytesAndBlobEditsUseRevision(t *testing.T) {
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	original := []byte{'#', 0xff, '\n', 'a', ':', ' ', 'b', '\n'}
	opts.LegacySettings = []byte(`{"profiles":[{"id":"legacy","autoUpdateDuration":86400000000}]}`)
	opts.ReadLegacySource = func(string) (string, error) { return string(original), nil }
	app := openTestApp(t, opts)
	request(t, app, "export-original", "profile.export", map[string]any{"profileId": "legacy"})
	receipt := waitDomain(t, app, "export-original")
	name, _ := app.blobPath(receipt.Blob.Token)
	data, err := os.ReadFile(name)
	if err != nil || !bytes.Equal(data, original) {
		t.Fatal("export changed original bytes", err)
	}
	old, _ := app.profiles.Get("legacy")
	request(t, app, "rename-original", "profile.put", map[string]any{"metadata": map[string]any{"id": "legacy", "label": "New label"}, "expectedRevision": old.Revision})
	waitDomain(t, app, "rename-original")
	blob := upload(t, app, []byte("rules: ['MATCH,DIRECT']\n"))
	request(t, app, "stale-edit", "profile.import.file", map[string]any{"token": blob.Token, "metadata": map[string]any{"id": "legacy"}, "expectedRevision": old.Revision})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	failed, err := app.Await(ctx, "stale-edit")
	if err != nil || failed.Status != "failed" {
		t.Fatal(failed, err)
	}
	current, _ := app.profiles.Get("legacy")
	if current.Source != string(original) {
		t.Fatal("stale file edit replaced the source")
	}
}
func TestCompatibleBackupRoundTripAndUnsafeArchive(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	source := "# original\nbase: &base {type: direct}\nproxies: []\nrules: ['MATCH,DIRECT']\n"
	request(t, app, "add", "profile.put", map[string]any{"metadata": map[string]any{"id": "one", "label": "Original"}, "source": source, "select": true})
	waitDomain(t, app, "add")
	request(t, app, "settings", "settings.patch", map[string]any{"patch": map[string]any{"futureSetting": map[string]any{"value": "preserve"}}})
	waitDomain(t, app, "settings")
	request(t, app, "export", "backup.export", nil)
	receipt := waitDomain(t, app, "export")
	if receipt.Blob == nil || receipt.Blob.Size <= 0 {
		t.Fatal("backup token missing", receipt)
	}
	name, _ := app.blobPath(receipt.Blob.Token)
	data, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, entry := range archive.File {
		names[entry.Name] = true
	}
	if !names["config.json"] || !names["profiles/one.yaml"] {
		t.Fatal("incompatible backup layout", names)
	}
	restored := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	blob := upload(t, restored, data)
	request(t, restored, "restore", "backup.restore", map[string]any{"token": blob.Token, "replace": true})
	waitDomain(t, restored, "restore")
	record, err := restored.ProfileSource("one")
	if err != nil || record.Source != source {
		t.Fatal("original source lost", record, err)
	}
	if !bytes.Contains(restored.Snapshot().Catalog.Settings["futureSetting"], []byte("preserve")) {
		t.Fatal("unknown backup setting lost")
	}
	// Traversal is refused before any profile/catalog changes.
	var malicious bytes.Buffer
	writer := zip.NewWriter(&malicious)
	entry, _ := writer.Create("config.json")
	_, _ = entry.Write([]byte(`{"profiles":[]}`))
	entry, _ = writer.Create("../outside")
	_, _ = entry.Write([]byte("bad"))
	_ = writer.Close()
	unsafeTarget := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	// Startup may retain resolved defaults. Settle that legitimate update
	// before attributing a catalog change to a rejected restore.
	waitCondition(t, func() bool { return unsafeTarget.Snapshot().Runtime.AppliedGeneration > 0 })
	unsafeTarget.retainAppliedSettings(context.Background())
	bad := upload(t, unsafeTarget, malicious.Bytes())
	revision := unsafeTarget.Snapshot().Catalog.Revision
	request(t, unsafeTarget, "unsafe", "backup.restore", map[string]any{"token": bad.Token, "replace": true})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result, err := unsafeTarget.Await(ctx, "unsafe")
	if err != nil || result.Status != "failed" || unsafeTarget.Snapshot().Catalog.Revision != revision {
		t.Fatal("unsafe archive adopted", result, err)
	}
	if _, err = os.Stat(filepath.Join(unsafeTarget.directory, "outside")); !os.IsNotExist(err) {
		t.Fatal("archive escaped its root")
	}
}
func TestTransferRetryAndRangeGuards(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	blob, err := app.newBlob()
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.StdEncoding.EncodeToString([]byte("source"))
	first, err := app.appendBlob(context.Background(), blob.Token, 0, encoded)
	if err != nil {
		t.Fatal(err)
	}
	second, err := app.appendBlob(context.Background(), blob.Token, 0, encoded)
	if err != nil || second != first {
		t.Fatal("lost acknowledgement retry", second, err)
	}
	if _, err = app.appendBlob(context.Background(), blob.Token, 0, base64.StdEncoding.EncodeToString([]byte("change"))); err == nil {
		t.Fatal("conflicting retry replaced source")
	}
	raw, err := app.readBlob(blob.Token, 0, blobChunkBytes)
	if err != nil {
		t.Fatal(err)
	}
	encodedResponse, _ := json.Marshal(raw)
	if !bytes.Contains(encodedResponse, []byte(encoded)) {
		t.Fatal("chunk download mismatch")
	}
	if _, err = app.readBlob("../../outside", 0, 10); err == nil {
		t.Fatal("unsafe transfer path accepted")
	}
}

func TestBackupPreservesMissingSourcesAndCanDownloadThemAfterRestore(t *testing.T) {
	const source = "rules: ['MATCH,DIRECT']\n"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, source)
	}))
	defer server.Close()
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opts.LegacySettings = jsonValue(map[string]any{
		"currentProfileId": "present",
		"profiles": []map[string]any{
			{"id": "present"},
			{"id": "missing", "url": server.URL},
			{"id": "empty"},
		},
	})
	opts.ReadLegacySource = func(id string) (string, error) {
		switch id {
		case "missing":
			return "", os.ErrNotExist
		case "empty":
			return "", nil
		default:
			return source, nil
		}
	}
	app := openTestApp(t, opts)
	waitCondition(t, func() bool { return app.Snapshot().Runtime.AppliedGeneration > 0 })
	request(t, app, "export", "backup.export", nil)
	receipt := waitDomain(t, app, "export")
	name, _ := app.blobPath(receipt.Blob.Token)
	data, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	restored := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	blob := upload(t, restored, data)
	request(t, restored, "restore", "backup.restore", map[string]any{"token": blob.Token, "replace": true})
	waitDomain(t, restored, "restore")
	for _, id := range []string{"present", "missing", "empty"} {
		record, err := restored.ProfileSource(id)
		if err != nil || record.SourceMissing != (id == "missing") {
			t.Fatalf("backup changed source availability for %s: missing=%v, %v", id, record.SourceMissing, err)
		}
		if id == "present" && record.Source != source || id == "empty" && record.Source != "" {
			t.Fatalf("backup changed original bytes for %s", id)
		}
	}
	request(t, restored, "select-missing", "profile.select", map[string]any{"profileId": "missing"})
	waitDomain(t, restored, "select-missing")
	record, err := restored.ProfileSource("missing")
	if err != nil || record.SourceMissing || record.Source != source {
		t.Fatalf("restored subscription could not recover its source: missing=%v, %v", record.SourceMissing, err)
	}
}

func TestAggregateQuotaAppliesToReservedUploadsAndExports(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	blobs := make([]Blob, 5)
	for index := range blobs {
		var err error
		blobs[index], err = app.newBlob()
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, blob := range blobs[:4] {
		name, _ := app.blobPath(blob.Token)
		// Sparse fixtures account for logical bytes without allocating 512 MiB.
		if err := os.Truncate(name, maxBlobBytes); err != nil {
			t.Fatal(err)
		}
	}
	last := blobs[4]
	if _, err := app.appendBlob(context.Background(), last.Token, 0, base64.StdEncoding.EncodeToString([]byte("x"))); err == nil {
		t.Fatal("reserved upload escaped aggregate quota")
	}
	if _, err := app.writeBlob(context.Background(), last.Token, func(writer io.Writer) error { _, err := writer.Write([]byte("x")); return err }); err == nil {
		t.Fatal("export escaped aggregate quota")
	}
	for _, blob := range blobs {
		_ = app.removeBlob(blob.Token)
	}
}
