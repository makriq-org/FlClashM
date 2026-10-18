package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestHeadlessPresentationAutorunAndLastProfileDeletion(t *testing.T) {
	dir := t.TempDir()
	opt := options(t, dir, &testEngine{}, make(chan time.Time))
	opt.LegacySettings = []byte(`{"appSetting":{"autoRun":true,"testUrl":""},"profiles":[{"id":"one","label":"Fallback","selectedMap":{"Select":"Server"},"providerHeaders":{"flclashm-servicename":"` + base64.StdEncoding.EncodeToString([]byte("Service")) + `","flclashm-serverinfo":"` + base64.StdEncoding.EncodeToString([]byte("Select")) + `","flclashm-globalmode":"false"}}],"currentProfileId":"one"}`)
	opt.ReadLegacySource = func(string) (string, error) {
		return "proxy-groups: [{name: Select, type: select, proxies: [DIRECT]}]\nrules: ['MATCH,DIRECT']", nil
	}
	app := openTestApp(t, opt)
	request(t, app, "session", "ui.attach", nil)
	opened := waitDomain(t, app, "session")
	if opened.RuntimeOperationID == "" {
		t.Fatal("Go autorun did not start selected profile")
	}
	waitRuntime(t, app, opened.RuntimeOperationID)
	presentation := app.Presentation()
	if presentation.NotificationTitle != "Service / Server" || !presentation.HasActiveProfile || presentation.GlobalModeEnabled {
		t.Fatal("native presentation", presentation)
	}
	request(t, app, "stop", "runtime.stop", nil)
	waitRuntime(t, app, "stop")
	request(t, app, "session", "ui.attach", nil)
	if app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("UI reattach replayed autostart after user stop")
	}
	request(t, app, "again", "runtime.start", nil)
	waitRuntime(t, app, "again")
	record, err := app.profiles.Get("one")
	if err != nil {
		t.Fatal(err)
	}
	request(t, app, "delete", "profile.delete", map[string]any{"profileId": "one", "expectedRevision": record.Revision})
	deleted := waitDomain(t, app, "delete")
	waitRuntime(t, app, deleted.RuntimeOperationID)
	if len(app.Snapshot().Catalog.Profiles) != 0 || app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("last profile deletion did not stop")
	}
	request(t, app, "recover", "runtime.recover", nil)
	waitRuntime(t, app, "recover")
	if app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("deleted profile recovered")
	}
}
func TestResetKeepsMigrationMarkerAndFencesOldSource(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	request(t, app, "put", "profile.put", map[string]any{"metadata": map[string]any{"id": "one", "future": "preserved"}, "source": "rules: ['MATCH,DIRECT']", "select": true})
	waitDomain(t, app, "put")
	record, _ := app.profiles.Get("one")
	request(t, app, "edit", "profile.put", map[string]any{"metadata": map[string]any{"id": "one"}, "source": "rules: ['MATCH,REJECT']", "expectedRevision": record.Revision})
	waitDomain(t, app, "edit")
	updated, _ := app.profiles.Get("one")
	var future string
	_ = json.Unmarshal(updated.Metadata["future"], &future)
	if future != "preserved" {
		t.Fatal("document editor lost unknown metadata")
	}
	request(t, app, "reset", "data.reset", nil)
	waitDomain(t, app, "reset")
	snapshot := app.Snapshot()
	if !snapshot.Catalog.Migrated || len(snapshot.Catalog.Profiles) != 0 || snapshot.Runtime.AppliedGeneration != 0 {
		t.Fatal("incomplete reset", snapshot)
	}
	plan, input, err := app.runtime.Applied()
	if err != nil || plan != nil || len(input) != 0 {
		t.Fatal("reset retained source", err)
	}
}

func TestMissingLegacyURLSourceDownloadsAsCancellableFencedOperation(t *testing.T) {
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		select {
		case <-release:
			_, _ = w.Write([]byte("rules: ['MATCH,DIRECT']"))
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	opt := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opt.LegacySettings = []byte(`{"appSetting":{"testUrl":""},"profiles":[{"id":"missing","url":"` + server.URL + `","autoUpdate":false}],"currentProfileId":"missing"}`)
	opt.ReadLegacySource = func(string) (string, error) { return "", os.ErrNotExist }
	app := openTestApp(t, opt)
	request(t, app, "fetch-start", "runtime.start", nil)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("start did not fetch original source")
	}
	request(t, app, "stop-during-fetch", "runtime.stop", nil)
	waitRuntime(t, app, "stop-during-fetch")
	close(release)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	receipt, err := app.Await(ctx, "fetch-start")
	if err != nil || receipt.Status != "failed" {
		t.Fatal("stale download accepted", receipt, err)
	}
	if app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("late subscription resurrected VPN")
	}
	record, err := app.ProfileSource("missing")
	if err != nil || record.SourceMissing || record.Source != "rules: ['MATCH,DIRECT']" {
		t.Fatal("source recovery lost original", record, err)
	}
	request(t, app, "retry", "runtime.start", nil)
	waitRuntime(t, app, "retry")
	if app.Snapshot().Runtime.Observed.State != "running" {
		t.Fatal("cached source did not start")
	}
}

type deniedPermissionPlatform struct{ testPlatform }

func (deniedPermissionPlatform) VPNPermission(context.Context) (bool, error) { return false, nil }
func TestProxyOnlyAutorunDoesNotRequestVPNAndEmptyCatalogCannotConnect(t *testing.T) {
	opt := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opt.Platform = &deniedPermissionPlatform{}
	opt.LegacySettings = []byte(`{"appSetting":{"autoRun":true,"testUrl":""},"vpnProps":{"enable":false},"profiles":[{"id":"one"}],"currentProfileId":"one"}`)
	opt.ReadLegacySource = func(string) (string, error) { return "rules: ['MATCH,DIRECT']", nil }
	app := openTestApp(t, opt)
	request(t, app, "open", "ui.attach", nil)
	receipt := waitDomain(t, app, "open")
	if receipt.PermissionRequired || receipt.RuntimeOperationID == "" || app.Presentation().RequiresVPN {
		t.Fatal("proxy-only execution requested VPN consent", receipt)
	}
	request(t, app, "clear", "data.reset", nil)
	waitDomain(t, app, "clear")
	raw, _ := json.Marshal(map[string]any{"apiVersion": 1, "operationId": "empty", "method": "runtime.start"})
	var response struct {
		Error any `json:"error"`
	}
	_ = json.Unmarshal(app.Handle(raw), &response)
	if response.Error == nil || app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("empty catalog started a direct VPN")
	}
}
