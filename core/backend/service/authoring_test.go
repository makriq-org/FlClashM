package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"core/backend"
	"core/backend/authoring"
	"core/backend/compile"
	"core/backend/profiles"
	"github.com/metacubex/age"
	"github.com/metacubex/age/armor"
)

func authoringRequest(t *testing.T, app *App) authoring.Snapshot {
	t.Helper()
	var result authoring.Snapshot
	if err := json.Unmarshal(request(t, app, newID("read"), "authoring.snapshot", nil), &result); err != nil {
		t.Fatal(err)
	}
	return result
}
func testAuthoringApp(t *testing.T) (*App, Options) {
	t.Helper()
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	app := openTestApp(t, opts)
	waitCondition(t, func() bool { return len(app.profiles.Snapshot().Settings["patchClashConfig"]) > 0 })
	return app, opts
}
func collectionRow(value any) authoring.Object {
	raw, _ := json.Marshal(value)
	var result authoring.Object
	_ = json.Unmarshal(raw, &result)
	return result
}
func testBlob(t *testing.T, app *App, data []byte) Blob {
	t.Helper()
	blob, err := app.newBlob()
	if err != nil {
		t.Fatal(err)
	}
	blob.Size, err = app.writeBlob(context.Background(), blob.Token, func(w io.Writer) error { _, err := w.Write(data); return err })
	if err != nil {
		t.Fatal(err)
	}
	return blob
}
func readBlobBytes(t *testing.T, app *App, blob *Blob) []byte {
	t.Helper()
	if blob == nil {
		t.Fatal("missing blob")
	}
	name, err := app.blobPath(blob.Token)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(data)) != blob.Size {
		t.Fatal("wrong blob size")
	}
	return data
}

func TestAuthoringUIContractCustomInspectRenderPreviewAndCAS(t *testing.T) {
	app, _ := testAuthoringApp(t)
	request(t, app, "custom-create", "profile.put", map[string]any{"metadata": map[string]any{"id": "custom:9007199254740993", "type": "custom", "label": "Custom"}})
	waitDomain(t, app, "custom-create")
	id := "custom:9007199254740993"
	record, err := app.ProfileSource(id)
	if err != nil || record.SourceMissing || string(record.Metadata["type"]) != `"custom"` {
		t.Fatal("custom source-less create failed", record, err)
	}
	snapshot := authoringRequest(t, app)
	if len(snapshot.Collections) != 9 {
		t.Fatal("missing collections", snapshot)
	}
	c := snapshot.Collections
	c["customProxies"] = []authoring.Object{collectionRow(map[string]any{"id": int64(9007199254740993), "definition": map[string]any{"name": "Local", "type": "socks5", "server": "example.com", "port": 443}})}
	c["proxyGroups"] = []authoring.Object{collectionRow(map[string]any{"id": 2, "profileId": id, "name": "Proxy", "type": "select", "proxies": []string{"Local"}})}
	c["rules"] = []authoring.Object{collectionRow(map[string]any{"id": 3, "profileId": id, "ruleAction": "MATCH", "ruleTarget": "Proxy"})}
	request(t, app, "authoring-save", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "collections": c})
	saved := waitDomain(t, app, "authoring-save")
	if saved.Revision != snapshot.Revision+1 {
		t.Fatal("receipt lost CAS revision", saved)
	}
	// Same operation ID must return the original receipt without repeating a write.
	request(t, app, "authoring-save", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "collections": c})
	if again := waitDomain(t, app, "authoring-save"); again.Revision != saved.Revision {
		t.Fatal("retried authoring mutated data")
	}
	request(t, app, "stale-authoring", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "collections": c})
	failed, err := app.Await(context.Background(), "stale-authoring")
	if err != nil || failed.Status != "failed" || failed.ErrorCode != "conflict" {
		t.Fatal("stale authoring write did not produce conflict receipt", failed, err)
	}
	var inspect struct {
		Config    compile.Object `json:"config"`
		Outbounds compile.Object `json:"outbounds"`
		Base      compile.Object `json:"base"`
	}
	_ = json.Unmarshal(request(t, app, "inspect-custom", "profile.inspect", map[string]any{"profileId": id}), &inspect)
	if len(inspect.Config["proxies"].([]any)) != 1 || inspect.Base["proxies"] != float64(1) || inspect.Base["digest"] == "" || inspect.Base["rules"] != float64(1) || inspect.Outbounds["proxy-groups"] == nil {
		t.Fatal("incomplete inspect contract", inspect)
	}
	generation := app.Snapshot().Runtime.Generation
	request(t, app, "render-custom", "profile.render", map[string]any{"profileId": id})
	rendered := waitDomain(t, app, "render-custom")
	raw := readBlobBytes(t, app, rendered.Blob)
	if !strings.Contains(string(raw), `"MATCH,Proxy"`) || rendered.RuntimeOperationID != "" || app.Snapshot().Runtime.Generation != generation {
		t.Fatal("render failed or changed runtime", rendered, string(raw))
	}
	var preview struct {
		Config compile.Object `json:"config"`
	}
	_ = json.Unmarshal(request(t, app, "script-preview", "authoring.evaluate", map[string]any{"script": "function main(c){c.preview=true;return c}", "config": map[string]any{"rules": []string{"MATCH,DIRECT"}}}), &preview)
	if preview.Config["preview"] != true || app.Snapshot().Runtime.Generation != generation {
		t.Fatal("preview did not remain isolated", preview)
	}
	// Source-less requests keep old profile.validate receipt semantics; explicit
	// ageSecretKey selects the new synchronous editor validation result.
	invalid := testBlob(t, app, []byte("proxies: ["))
	var validation map[string]string
	_ = json.Unmarshal(request(t, app, "validate-invalid", "profile.validate", map[string]any{"token": invalid.Token, "ageSecretKey": ""}), &validation)
	if validation["message"] == "" {
		t.Fatal("invalid source reported success")
	}
	valid := testBlob(t, app, []byte("rules: ['MATCH,DIRECT']"))
	_ = json.Unmarshal(request(t, app, "validate-valid", "profile.validate", map[string]any{"token": valid.Token, "ageSecretKey": ""}), &validation)
	if validation["message"] != "" {
		t.Fatal(validation)
	}
	request(t, app, "validate-legacy", "profile.validate", map[string]any{"source": "rules: ['MATCH,DIRECT']"})
	waitDomain(t, app, "validate-legacy")
}
func TestAuthoringImportRenamesReferencesAndRoundTripsBackup(t *testing.T) {
	app, opts := testAuthoringApp(t)
	request(t, app, "existing-custom", "profile.put", map[string]any{"metadata": map[string]any{"id": "existing", "type": "custom", "label": "Existing"}})
	waitDomain(t, app, "existing-custom")
	snapshot := authoringRequest(t, app)
	snapshot.Collections["customProxies"] = []authoring.Object{collectionRow(map[string]any{"id": 1, "definition": map[string]any{"name": "Server", "type": "socks5", "server": "held.example", "port": 443}})}
	request(t, app, "existing-authoring", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "collections": snapshot.Collections})
	waitDomain(t, app, "existing-authoring")
	yaml := `proxies:
 - {name: Server, type: socks5, server: imported.example, port: 1080, dialer-proxy: DIRECT}
proxy-groups:
 - {name: Proxy, type: select, proxies: [Server], use: [Feed]}
proxy-providers:
 Feed: {type: inline, payload: [{name: ProviderServer, type: socks5, server: provider.example, port: 443}]}
rule-providers:
 Domains: {type: inline, behavior: domain, payload: ['+.example.com']}
rules: ['RULE-SET,Domains,Proxy', 'MATCH,Proxy']
dns: {enable: true, nameserver: ['https://dns.google/dns-query#Proxy']}
ntp: {server: time.example}
future-config: {keep: true}
`
	snapshot = authoringRequest(t, app)
	blob := testBlob(t, app, []byte(yaml))
	request(t, app, "import-custom", "authoring.import", map[string]any{"token": blob.Token, "profileId": "imported:string-id", "metadata": map[string]any{"label": "Imported"}, "expectedRevision": snapshot.Revision, "select": true})
	imported := waitDomain(t, app, "import-custom")
	if imported.ProfileID != "imported:string-id" {
		t.Fatal("lost string id", imported)
	}
	data := authoringRequest(t, app)
	if len(data.Collections["customProxies"]) != 2 || len(data.Collections["clashProviders"]) != 1 || len(app.Snapshot().Catalog.Profiles) != 3 {
		t.Fatal("import lost dependencies", data)
	}
	var view compile.Prepared
	raw, _ := app.RuntimeView()
	if err := json.Unmarshal(raw, &view); err != nil {
		t.Fatal(err)
	}
	if view.ProfileID != "imported:string-id" || len(view.Config["proxies"].([]any)) != 1 {
		t.Fatal("import did not compile", view)
	}
	proxy := mapValue(view.Config["proxies"].([]any)[0])
	if proxy["name"] != "Server(1)" || proxy["dialer-proxy"] != "DIRECT" {
		t.Fatal("collision/dialer import failed", proxy)
	}
	if mapValue(view.Config["future-config"])["keep"] != true {
		t.Fatal("import lost unmodeled config fields")
	}
	request(t, app, "backup-authoring", "backup.export", nil)
	backup := waitDomain(t, app, "backup-authoring")
	archive := readBlobBytes(t, app, backup.Blob)
	restoredOpts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	restored := openTestApp(t, restoredOpts)
	waitCondition(t, func() bool { return len(restored.profiles.Snapshot().Settings["patchClashConfig"]) > 0 })
	uploaded := testBlob(t, restored, archive)
	request(t, restored, "restore-authoring", "backup.restore", map[string]any{"token": uploaded.Token, "replace": true})
	waitDomain(t, restored, "restore-authoring")
	if !reflect.DeepEqual(data.Collections, authoringRequest(t, restored).Collections) {
		t.Fatal("backup restore lost custom dependencies")
	}
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openTestApp(t, opts)
	if !reflect.DeepEqual(data.Collections, authoringRequest(t, reopened).Collections) {
		t.Fatal("reopen lost declarations")
	}
	request(t, reopened, "reset-authoring", "data.reset", nil)
	waitDomain(t, reopened, "reset-authoring")
	if len(authoringRequest(t, reopened).Collections["customProxies"]) != 0 || len(reopened.Snapshot().Catalog.Profiles) != 0 {
		t.Fatal("reset retained authoring")
	}
}
func TestResourceUpdateCASOwnedDownloadAndRead(t *testing.T) {
	var block atomic.Bool
	started, release := make(chan struct{}, 1), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if block.Load() {
			started <- struct{}{}
			<-release
		}
		_, _ = io.WriteString(w, "payload: ['+.example.com']")
	}))
	defer server.Close()
	app, _ := testAuthoringApp(t)
	snapshot := authoringRequest(t, app)
	snapshot.Collections["clashProviders"] = []authoring.Object{collectionRow(map[string]any{"id": int64(9007199254740993), "label": "Domains", "url": server.URL, "contentBase64": "", "behavior": "classical", "format": "yaml"})}
	request(t, app, "resource-declare", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "collections": snapshot.Collections})
	waitDomain(t, app, "resource-declare")
	request(t, app, "resource-update", "authoring.resource.update", map[string]any{"collection": "clashProviders", "id": int64(9007199254740993)})
	updated := waitDomain(t, app, "resource-update")
	var read struct {
		Content      string `json:"contentBase64"`
		Size         int    `json:"size"`
		LastModified string `json:"lastModified"`
	}
	_ = json.Unmarshal(request(t, app, "resource-read", "authoring.resource.read", map[string]any{"collection": "clashProviders", "id": int64(9007199254740993)}), &read)
	bytes, err := base64.StdEncoding.DecodeString(read.Content)
	if err != nil || read.Size != len(bytes) || read.LastModified == "" || updated.Revision == 0 {
		t.Fatal("resource read contract", read, err)
	}
	block.Store(true)
	request(t, app, "resource-race", "authoring.resource.update", map[string]any{"collection": "clashProviders", "id": int64(9007199254740993)})
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("download did not start")
	}
	snapshot = authoringRequest(t, app)
	snapshot.Collections["clashProviders"][0]["url"] = jsonValue(server.URL + "/edited")
	if err = app.profiles.ReplaceAuthoring(context.Background(), snapshot.Collections, snapshot.Revision); err != nil {
		t.Fatal(err)
	}
	close(release)
	failed, err := app.Await(context.Background(), "resource-race")
	if err != nil || failed.Status != "failed" || failed.ErrorCode != "conflict" {
		t.Fatal("late resource download overwrote authoring", failed, err)
	}
	if authoring.String(authoringRequest(t, app).Collections["clashProviders"][0], "url") != server.URL+"/edited" {
		t.Fatal("late response changed URL")
	}
}
func TestPreviewAgeAndShareLinkImportsUsePureCodecs(t *testing.T) {
	app, _ := testAuthoringApp(t)
	identity, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	var encrypted bytes.Buffer
	armored := armor.NewWriter(&encrypted)
	writer, err := age.Encrypt(armored, identity.Recipient())
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.WriteString(writer, "rules: ['MATCH,DIRECT']")
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err = armored.Close(); err != nil {
		t.Fatal(err)
	}
	blob := testBlob(t, app, encrypted.Bytes())
	var validation map[string]string
	_ = json.Unmarshal(request(t, app, "age-validation", "profile.validate", map[string]any{"token": blob.Token, "ageSecretKey": identity.String()}), &validation)
	if validation["message"] != "" {
		t.Fatal(validation)
	}
	link := "socks5://user:pass@example.com:1080#LinkServer"
	var parsed struct {
		Proxies []compile.Object `json:"proxies"`
	}
	_ = json.Unmarshal(request(t, app, "parse-links", "authoring.parseLinks", map[string]any{"source": link}), &parsed)
	if len(parsed.Proxies) != 1 || parsed.Proxies[0]["name"] != "LinkServer" {
		t.Fatal("pure link parsing failed", parsed)
	}
	snapshot := authoringRequest(t, app)
	request(t, app, "import-links", "authoring.import", map[string]any{"source": link, "links": true, "expectedRevision": snapshot.Revision})
	receipt := waitDomain(t, app, "import-links")
	if receipt.ProfileID == "" || len(authoringRequest(t, app).Collections["customProxies"]) != 1 {
		t.Fatal("link import did not persist")
	}
}
func TestResourceReadRejectsArbitraryPaths(t *testing.T) {
	app, _ := testAuthoringApp(t)
	_, _, err := app.profiles.Resource(context.Background(), "../../secrets", "1")
	if err == nil || errors.Is(err, profiles.ErrNotFound) {
		t.Fatal("arbitrary resource collection accepted")
	}
	raw, _ := json.Marshal(backend.Request{APIVersion: 1, OperationID: "forbidden", Method: "authoring.resource.read", Input: json.RawMessage(`{"collection":"scripts","id":1,"path":"/etc/passwd"}`)})
	var response backend.Response
	_ = json.Unmarshal(app.Handle(raw), &response)
	if response.Error == nil {
		t.Fatal("arbitrary resource path accepted")
	}
}

func TestCapturePreservesOrderedProfileOverridePolicies(t *testing.T) {
	app, _ := testAuthoringApp(t)
	metadata := profiles.Object{"id": jsonValue("ordered"), "overrides": json.RawMessage(`{"dns-override-keys":["nameserver-policy"],"dns":{"nameserver-policy":{"geosite:z":"9.9.9.9","+.a.test":"1.1.1.1"}}}`)}
	if _, err := app.profiles.Put(context.Background(), metadata, "dns: {enable: true, nameserver: [https://dns.google/dns-query]}\nrules: ['MATCH,DIRECT']", 0); err != nil {
		t.Fatal(err)
	}
	id := "ordered"
	captured, err := app.captureProfileInput(&id)
	if err != nil {
		t.Fatal(err)
	}
	config, err := app.compiler.BuildProfile(context.Background(), captured)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(config)
	if bytes.Index(raw, []byte(`"geosite:z"`)) > bytes.Index(raw, []byte(`"+.a.test"`)) {
		t.Fatal("catalog capture reordered selected policy", string(raw))
	}
}

func TestRepeatedCustomImportKeepsLabelAndDeduplicatesDialers(t *testing.T) {
	app, _ := testAuthoringApp(t)
	source := `proxies:
 - {name: A, type: socks5, server: same.example, port: 443, dialer-proxy: DIRECT}
 - {name: B, type: socks5, server: same.example, port: 443, dialer-proxy: DIRECT}
proxy-groups: [{name: Proxy, type: select, proxies: [A, B]}]
rules: ['MATCH,Proxy']`
	for i := 0; i < 2; i++ {
		snapshot := authoringRequest(t, app)
		id := fmt.Sprintf("reimport-%d", i)
		request(t, app, id, "authoring.import", map[string]any{"source": source, "profileId": "existing-custom-import", "metadata": map[string]any{"label": "Keep label"}, "replace": true, "expectedRevision": snapshot.Revision})
		waitDomain(t, app, id)
		record, err := app.ProfileSource("existing-custom-import")
		if err != nil || string(record.Metadata["label"]) != `"Keep label"` {
			t.Fatal("reimport renamed its own profile", record, err)
		}
		data := authoringRequest(t, app)
		if len(data.Collections["customProxies"]) != 1 || len(data.Collections["proxyDialers"]) != 1 || len(data.Collections["proxyGroups"]) != 1 {
			t.Fatal("deduplicated import left duplicate declarations", data)
		}
	}
}
func TestAuthoringSaveSurvivesIsolatedCompilationFailure(t *testing.T) {
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opts.Compiler.Validate = func(_ context.Context, config compile.Object) error {
		if config["test-invalid"] == true {
			return errors.New("isolated validator rejected edited profile")
		}
		return nil
	}
	app := openTestApp(t, opts)
	waitCondition(t, func() bool { return len(app.profiles.Snapshot().Settings["patchClashConfig"]) > 0 })
	request(t, app, "prepare-save-failure", "profile.put", map[string]any{"metadata": map[string]any{"id": "save-failure", "type": "custom", "label": "Initial"}, "select": true})
	waitDomain(t, app, "prepare-save-failure")
	snapshot := authoringRequest(t, app)
	request(t, app, "saved-invalid", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "profiles": []any{map[string]any{"id": "save-failure", "label": "Saved edit", "customConfig": map[string]any{"test-invalid": true}}}, "collections": snapshot.Collections})
	receipt, err := app.Await(context.Background(), "saved-invalid")
	if err != nil || receipt.Revision != snapshot.Revision+1 || receipt.RuntimeOperationID == "" {
		t.Fatal("save was not recorded", receipt, err)
	}
	runtimeReceipt, err := app.AwaitRuntime(context.Background(), receipt.RuntimeOperationID)
	if err == nil && runtimeReceipt.Status != "failed" {
		t.Fatal("injected validation failure reported success", runtimeReceipt)
	}
	saved, err := app.ProfileSource("save-failure")
	if err != nil || string(saved.Metadata["label"]) != `"Saved edit"` {
		t.Fatal("failed compilation erased committed editor data", saved, err)
	}
}
