package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
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
	bad := upload(t, restored, malicious.Bytes())
	revision := restored.Snapshot().Catalog.Revision
	request(t, restored, "unsafe", "backup.restore", map[string]any{"token": bad.Token, "replace": true})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result, err := restored.Await(ctx, "unsafe")
	if err != nil || result.Status != "failed" || restored.Snapshot().Catalog.Revision != revision {
		t.Fatal("unsafe archive adopted", result, err)
	}
	if _, err = os.Stat(filepath.Join(restored.directory, "outside")); !os.IsNotExist(err) {
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
