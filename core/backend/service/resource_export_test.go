package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"core/backend"
	"core/backend/authoring"
	"core/profilecodec"
)

func failedResourceExport(t *testing.T, app *App, method string, params any) Receipt {
	t.Helper()
	id := newID("failed-export")
	request(t, app, id, method, params)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	receipt, err := app.Await(ctx, id)
	if err != nil || receipt.Status != "failed" || receipt.Blob != nil || receipt.Error == "" {
		t.Fatalf("expected failed export: %+v %v", receipt, err)
	}
	return receipt
}

func TestProviderInspectExportCallbackAndBlobContract(t *testing.T) {
	_, mrs, err := profilecodec.CompileRules([]byte("+.example.com\n"), false)
	if err != nil {
		t.Fatal(err)
	}
	resources := map[string][]byte{"text": []byte("# exact UTF-8\r\n"), "mrs": mrs, "binary": {0xff, 0xfe}}
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opts.ReadProviderResource = func(ctx context.Context, name, kind string) ([]byte, error) {
		if kind != "rule" {
			return nil, errors.New("wrong kind")
		}
		data, ok := resources[name]
		if !ok {
			return nil, errors.New("unknown provider")
		}
		return data, ctx.Err()
	}
	app := openTestApp(t, opts)
	for name, data := range resources {
		var inspection struct {
			Format   string `json:"format"`
			Size     int    `json:"size"`
			Editable bool   `json:"editable"`
		}
		if err := json.Unmarshal(request(t, app, newID("inspect"), "provider.inspect", map[string]any{"name": name, "type": "rule"}), &inspection); err != nil {
			t.Fatal(err)
		}
		if inspection.Format != name || inspection.Size != len(data) || inspection.Editable != (name == "text") {
			t.Fatalf("inspection: %+v", inspection)
		}
		id := newID("export")
		request(t, app, id, "provider.export", map[string]any{"name": name, "type": "rule"})
		receipt := waitDomain(t, app, id)
		if !bytes.Equal(data, readBlobBytes(t, app, receipt.Blob)) {
			t.Fatal("raw export changed bytes")
		}
		// Verify public chunked transfer and retry, not only the on-disk file.
		var chunk struct {
			Data string `json:"data"`
			Size int64  `json:"size"`
			EOF  bool   `json:"eof"`
		}
		if err := json.Unmarshal(request(t, app, newID("chunk"), "blob.read", map[string]any{"token": receipt.Blob.Token, "offset": 0, "limit": blobChunkBytes}), &chunk); err != nil {
			t.Fatal(err)
		}
		decoded, err := base64.StdEncoding.DecodeString(chunk.Data)
		if err != nil || !bytes.Equal(decoded, data) || !chunk.EOF || chunk.Size != int64(len(data)) {
			t.Fatal("invalid blob contract", chunk, err)
		}
		request(t, app, id, "provider.export", map[string]any{"name": name, "type": "rule"})
		if retry := waitDomain(t, app, id); retry.Blob.Token != receipt.Blob.Token {
			t.Fatal("retry created another blob")
		}
		if name == "binary" {
			failedResourceExport(t, app, "provider.export", map[string]any{"name": name, "type": "rule", "asText": true})
			continue
		}
		id = newID("export-text")
		request(t, app, id, "provider.export", map[string]any{"name": name, "type": "rule", "asText": true})
		text := readBlobBytes(t, app, waitDomain(t, app, id).Blob)
		expected, err := profilecodec.DumpRules(data)
		if err != nil || !bytes.Equal(text, expected) {
			t.Fatal("text export mismatch", err)
		}
	}
	failedResourceExport(t, app, "provider.export", map[string]any{"name": "missing", "type": "rule"})
}

func TestProviderResourcesRejectNilUnknownFieldsKindsAndLimits(t *testing.T) {
	app, _ := testAuthoringApp(t)
	if receipt := failedResourceExport(t, app, "provider.export", map[string]any{"name": "x", "type": "rule"}); !strings.Contains(receipt.Error, "unavailable") {
		t.Fatal("nil callback hid error", receipt)
	}
	for _, params := range []map[string]any{
		{"name": "x", "type": "rule", "path": "/etc/passwd"},
		{"name": "x", "type": "rule", "asText": true},
		{"name": "x", "type": "other"}, {"type": "rule"},
	} {
		raw, _ := json.Marshal(backend.Request{APIVersion: 1, OperationID: newID("inspect-invalid"), Method: "provider.inspect", Input: mustJSON(params)})
		var response backend.Response
		if err := json.Unmarshal(app.Handle(raw), &response); err != nil || response.Error == nil {
			t.Fatal("accepted invalid inspect", params, err)
		}
	}
	for _, params := range []map[string]any{
		{"name": "x", "type": "rule", "path": "/etc/passwd"}, {"name": "x", "type": "unknown"}, {"name": "x", "type": "rule", "extra": true},
	} {
		failedResourceExport(t, app, "provider.export", params)
	}
	failedResourceExport(t, app, "authoring.resource.export", map[string]any{"collection": "scripts", "id": 1, "path": "/etc/passwd"})
	app.readProviderResource = func(context.Context, string, string) ([]byte, error) {
		return make([]byte, profilecodec.MaxResourceBytes+1), nil
	}
	failedResourceExport(t, app, "provider.export", map[string]any{"name": "x", "type": "proxy"})
}

func mustJSON(value any) json.RawMessage { raw, _ := json.Marshal(value); return raw }

func TestProviderResourceRejectsBeforeCallbackAndHonorsCancellation(t *testing.T) {
	app, _ := testAuthoringApp(t)
	calls := 0
	app.readProviderResource = func(ctx context.Context, name, kind string) ([]byte, error) {
		calls++
		return []byte("payload: []"), ctx.Err()
	}
	for _, params := range []map[string]any{
		{"name": "x", "type": "rule", "path": "/etc/passwd"},
		{"name": "x", "type": "unknown"},
	} {
		failedResourceExport(t, app, "provider.export", params)
	}
	if calls != 0 {
		t.Fatal("invalid request reached provider callback")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := app.providerResource(ctx, providerResourceParams{Name: "x", Type: "rule"}); !errors.Is(err, context.Canceled) || calls != 0 {
		t.Fatal("cancelled read reached callback", err)
	}
	app.readProviderResource = nil
	raw, _ := json.Marshal(backend.Request{APIVersion: 1, OperationID: newID("nil-inspect"), Method: "provider.inspect", Input: mustJSON(map[string]any{"name": "x", "type": "rule"})})
	var response backend.Response
	if err := json.Unmarshal(app.Handle(raw), &response); err != nil || response.Error == nil || !strings.Contains(response.Error.Message, "unavailable") {
		t.Fatal("inspect hid nil callback", err)
	}
}

func TestAuthoringResourceExportUsesSavedBytesWithoutDownload(t *testing.T) {
	app, _ := testAuthoringApp(t)
	_, mrs, err := profilecodec.CompileRules([]byte("10.0.0.0/8\n2001:db8::/32"), false)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := authoringRequest(t, app)
	snapshot.Collections["clashProviders"] = []authoring.Object{
		collectionRow(map[string]any{"id": 1, "label": "saved", "url": "https://invalid.example/saved", "format": "mrs", "behavior": "ipcidr", "contentBase64": base64.StdEncoding.EncodeToString(mrs)}),
		collectionRow(map[string]any{"id": 2, "label": "remote", "url": "https://invalid.example/unfetched", "format": "text", "behavior": "domain"}),
	}
	snapshot.Collections["scripts"] = []authoring.Object{collectionRow(map[string]any{"id": 3, "label": "script", "content": "// точный текст\r\n"})}
	if err := app.profiles.ReplaceAuthoring(context.Background(), snapshot.Collections, snapshot.Revision); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		collection string
		id         int
		asText     bool
		expected   []byte
	}{
		{"clashProviders", 1, false, mrs}, {"scripts", 3, true, []byte("// точный текст\r\n")},
	} {
		id := newID("saved-export")
		request(t, app, id, "authoring.resource.export", map[string]any{"collection": test.collection, "id": test.id, "asText": test.asText})
		if got := readBlobBytes(t, app, waitDomain(t, app, id).Blob); !bytes.Equal(got, test.expected) {
			t.Fatal("saved bytes changed")
		}
	}
	id := newID("saved-mrs-text")
	request(t, app, id, "authoring.resource.export", map[string]any{"collection": "clashProviders", "id": 1, "asText": true})
	if text := readBlobBytes(t, app, waitDomain(t, app, id).Blob); !bytes.Contains(text, []byte("10.0.0.0/8")) {
		t.Fatal("MRS was not dumped", string(text))
	}
	failedResourceExport(t, app, "authoring.resource.export", map[string]any{"collection": "clashProviders", "id": 2})
	failedResourceExport(t, app, "authoring.resource.export", map[string]any{"collection": "unknown", "id": 1})
	var read struct {
		Size int `json:"size"`
	}
	if err := json.Unmarshal(request(t, app, newID("read-remote"), "authoring.resource.read", map[string]any{"collection": "clashProviders", "id": 2}), &read); err != nil || read.Size != 0 {
		t.Fatal("read contract changed", read, err)
	}
}

func TestResourceDownloadLimitPreservesSavedContent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chunk := bytes.Repeat([]byte{'x'}, 64<<10)
		for i := 0; i < 257; i++ {
			if _, err := w.Write(chunk); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	app, _ := testAuthoringApp(t)
	snapshot := authoringRequest(t, app)
	snapshot.Collections["scripts"] = []authoring.Object{collectionRow(map[string]any{"id": 1, "label": "bounded", "url": server.URL, "content": "original"})}
	if err := app.profiles.ReplaceAuthoring(context.Background(), snapshot.Collections, snapshot.Revision); err != nil {
		t.Fatal(err)
	}
	failedResourceExport(t, app, "authoring.resource.update", map[string]any{"collection": "scripts", "id": 1})
	row, _, err := app.profiles.Resource(context.Background(), "scripts", "1")
	if err != nil || authoring.String(row, "content") != "original" {
		t.Fatal("oversize download replaced saved bytes", err)
	}
}
