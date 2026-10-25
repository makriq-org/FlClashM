package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	"core/backend/authoring"
)

func authoringRow(value any) authoring.Object {
	raw, _ := json.Marshal(value)
	var row authoring.Object
	_ = json.Unmarshal(raw, &row)
	return row
}
func authoringFixture() authoring.Collections {
	c := authoring.Empty()
	c["customProxies"] = []authoring.Object{authoringRow(map[string]any{"id": int64(9007199254740993), "definition": map[string]any{"name": "Server", "type": "socks5", "server": "example.com", "port": 443}, "future": map[string]any{"exact": int64(9007199254740995)}})}
	c["proxyGroups"] = []authoring.Object{authoringRow(map[string]any{"id": 2, "profileId": "custom:9007199254740993", "name": "Proxy", "type": "select", "proxies": []string{"Server"}})}
	c["rules"] = []authoring.Object{authoringRow(map[string]any{"id": 3, "profileId": "custom:9007199254740993", "ruleAction": "MATCH", "ruleTarget": "Proxy"}), authoringRow(map[string]any{"id": 4, "profileId": nil, "ruleAction": "DOMAIN_SUFFIX", "content": "example.com", "ruleTarget": "DIRECT"})}
	c["disabledRules"] = []authoring.Object{authoringRow(map[string]any{"profileId": "custom:9007199254740993", "ruleId": 4})}
	c["scripts"] = []authoring.Object{authoringRow(map[string]any{"id": 5, "label": "script", "content": "function main(c){return c}", "future": true})}
	c["clashProviders"] = []authoring.Object{authoringRow(map[string]any{"id": 6, "label": "Rules", "contentBase64": "cGF5bG9hZDogW10K", "format": "yaml", "behavior": "classical"})}
	return c
}
func TestAuthoringCASReopenBackupResetAndLegacyPreservation(t *testing.T) {
	ctx := context.Background()
	directory := t.TempDir()
	validate := func(context.Context, string) error { return nil }
	r, err := Open(directory, validate)
	if err != nil {
		t.Fatal(err)
	}
	legacy := []byte(`{"profiles":[{"id":"legacy","overrideData":{"enable":true,"future":17}}],"currentProfileId":"legacy","scriptProps":{"scripts":[{"id":"old","content":"old"}]},"unknown":9007199254740993}`)
	if err = r.Migrate(ctx, legacy, func(string) (string, error) { return "rules: [MATCH,DIRECT]", nil }); err != nil {
		t.Fatal(err)
	}
	before, _ := r.ExportLegacy()
	_, err = r.Put(ctx, Object{"id": mustJSON("custom:9007199254740993"), "type": mustJSON("custom")}, "{}", 0)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := r.AuthoringSnapshot()
	c := authoringFixture()
	if err = r.ReplaceAuthoring(ctx, c, snapshot.Revision); err != nil {
		t.Fatal(err)
	}
	saved := r.AuthoringSnapshot()
	if saved.Revision != snapshot.Revision+1 {
		t.Fatal("wrong revision", saved)
	}
	c["customProxies"][0]["id"] = mustJSON(7)
	if authoring.ID(r.AuthoringSnapshot().Collections["customProxies"][0]["id"]) != "9007199254740993" {
		t.Fatal("caller mutated snapshot or lost integer precision")
	}
	if err = r.ReplaceAuthoring(ctx, saved.Collections, snapshot.Revision); !errors.Is(err, ErrConflict) {
		t.Fatal("accepted stale authoring CAS", err)
	}
	reopened, err := Open(directory, validate)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(saved, reopened.AuthoringSnapshot()) {
		t.Fatal("declarations changed on reopen")
	}
	exported, err := reopened.ExportLegacy()
	if err != nil {
		t.Fatal(err)
	}
	restored, err := Open(t.TempDir(), validate)
	if err != nil {
		t.Fatal(err)
	}
	if err = restored.Restore(ctx, exported, func(id string) (string, error) { record, err := r.Get(id); return record.Source, err }, false, true); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(saved.Collections, restored.AuthoringSnapshot().Collections) {
		t.Fatal("backup lost authoring or resource content")
	}
	var old, new Object
	_ = json.Unmarshal(before, &old)
	_ = json.Unmarshal(exported, &new)
	for _, key := range []string{"scriptProps", "unknown"} {
		if !reflect.DeepEqual(old[key], new[key]) {
			t.Fatalf("lost legacy %s", key)
		}
	}
	record, _ := restored.Get("legacy")
	if string(record.Metadata["overrideData"]) != `{"enable":true,"future":17}` {
		t.Fatal("legacy override changed", record)
	}
	prev := restored.Snapshot().Revision
	if err = restored.Reset(); err != nil {
		t.Fatal(err)
	}
	if restored.Snapshot().Revision != prev+1 || len(restored.Snapshot().Authoring) != 0 {
		t.Fatal("reset did not clear declarations monotonically")
	}
	if err = restored.Migrate(ctx, legacy, func(string) (string, error) { return "", os.ErrNotExist }); err != nil {
		t.Fatal(err)
	}
	if len(restored.Snapshot().Profiles) != 0 {
		t.Fatal("legacy resurrected reset data")
	}
}
func TestAuthoringRejectsInvalidReferencesAndCascades(t *testing.T) {
	ctx := context.Background()
	r, _ := Open(t.TempDir(), func(context.Context, string) error { return nil })
	record, err := r.Put(ctx, Object{"id": mustJSON("custom:9007199254740993"), "type": mustJSON("custom")}, "{}", 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(authoring.Collections){
		func(c authoring.Collections) { c["proxyGroups"][0]["profileId"] = mustJSON(42) },
		func(c authoring.Collections) { c["proxyGroups"][0]["proxies"] = mustJSON([]string{"missing"}) },
		func(c authoring.Collections) { c["proxyGroups"][0]["proxies"] = mustJSON([]string{"Proxy"}) },
		func(c authoring.Collections) {
			c["proxyDialers"] = []authoring.Object{authoringRow(map[string]any{"profileId": "custom:9007199254740993", "proxyId": int64(9007199254740993), "target": "Proxy"})}
		},
		func(c authoring.Collections) { c["disabledRules"][0]["ruleId"] = mustJSON(404) },
	} {
		c := authoringFixture()
		mutate(c)
		before := r.Snapshot()
		if err = r.ReplaceAuthoring(ctx, c, before.Revision); err == nil {
			t.Fatal("accepted broken relationship", c)
		}
		if !reflect.DeepEqual(before, r.Snapshot()) {
			t.Fatal("rejected write changed catalog")
		}
	}
	if err = r.ReplaceAuthoring(ctx, authoringFixture(), r.Snapshot().Revision); err != nil {
		t.Fatal(err)
	}
	if err = r.Delete("custom:9007199254740993", record.Revision); err != nil {
		t.Fatal(err)
	}
	c := r.AuthoringSnapshot().Collections
	if len(c["proxyGroups"])+len(c["proxyDialers"])+len(c["disabledRules"]) != 0 || len(c["rules"]) != 1 || len(c["customProxies"]) != 1 {
		t.Fatal("incorrect cascade", c)
	}
}

func TestAuthoringTransactionPreservesSourcesAndNeverPartiallyCommits(t *testing.T) {
	ctx := context.Background()
	r, _ := Open(t.TempDir(), func(context.Context, string) error { return nil })
	original := "rules: ['MATCH,DIRECT']\n# original bytes\n"
	old, err := r.Put(ctx, Object{"id": mustJSON("old"), "label": mustJSON("Old"), "opaque": mustJSON(map[string]any{"large": int64(9007199254740993)}), "overrideData": mustJSON(map[string]any{"enable": true, "future": true})}, original, 0)
	if err != nil {
		t.Fatal(err)
	}
	before := r.Snapshot()
	c := authoring.Empty()
	updates := []Object{{"id": mustJSON("old"), "label": mustJSON("Renamed")}, {"id": mustJSON("new-custom"), "label": mustJSON("New"), "type": mustJSON("custom")}}
	c["proxyGroups"] = []authoring.Object{authoringRow(map[string]any{"id": 1, "profileId": "new-custom", "name": "Proxy", "type": "select", "proxies": []string{"DIRECT"}})}
	if err = r.ReplaceAuthoringTransaction(ctx, c, updates, nil, before.Revision-1, nil); !errors.Is(err, ErrConflict) {
		t.Fatal("stale CAS accepted", err)
	}
	if !reflect.DeepEqual(before, r.Snapshot()) {
		t.Fatal("CAS failure committed metadata or declarations")
	}
	bad := clone(c)
	bad["proxyGroups"][0]["proxies"] = mustJSON([]string{"missing"})
	if err = r.ReplaceAuthoringTransaction(ctx, bad, updates, nil, before.Revision, nil); err == nil {
		t.Fatal("invalid declarations committed metadata")
	}
	if !reflect.DeepEqual(before, r.Snapshot()) {
		t.Fatal("validation failure partially committed")
	}
	if err = r.ReplaceAuthoringTransaction(ctx, c, updates, nil, before.Revision, nil); err != nil {
		t.Fatal(err)
	}
	retained, _ := r.Get("old")
	if retained.Source != original || retained.Digest != old.Digest || !reflect.DeepEqual(retained.Metadata["opaque"], old.Metadata["opaque"]) || !reflect.DeepEqual(retained.Metadata["overrideData"], old.Metadata["overrideData"]) {
		t.Fatal("metadata transaction lost source or unknown metadata", retained)
	}
	custom, _ := r.Get("new-custom")
	if custom.SourceMissing || custom.Source != "{}" {
		t.Fatal("custom profile creation needs no user source", custom)
	}
	saved := r.Snapshot()
	stopCalls := 0
	stopErr := errors.New("stop could not be journaled")
	if err = r.ReplaceAuthoringTransaction(ctx, c, nil, []string{"old", "new-custom"}, saved.Revision, func() error { stopCalls++; return stopErr }); !errors.Is(err, stopErr) {
		t.Fatal("last deletion ignored stop failure", err)
	}
	if !reflect.DeepEqual(saved, r.Snapshot()) {
		t.Fatal("stop failure removed data")
	}
	if err = r.ReplaceAuthoringTransaction(ctx, c, nil, []string{"old", "new-custom"}, saved.Revision, func() error { stopCalls++; return nil }); err != nil {
		t.Fatal(err)
	}
	if stopCalls != 2 || len(r.Snapshot().Profiles) != 0 || len(r.AuthoringSnapshot().Collections["proxyGroups"]) != 0 {
		t.Fatal("last deletion failed atomically")
	}
}
func TestProviderRenameUpdatesCustomReferencesAtomically(t *testing.T) {
	ctx := context.Background()
	r, _ := Open(t.TempDir(), func(context.Context, string) error { return nil })
	provider, err := r.Put(ctx, Object{"id": mustJSON("feed"), "label": mustJSON("Feed"), "type": mustJSON("url")}, "proxies: []", 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = r.Put(ctx, Object{"id": mustJSON("custom"), "type": mustJSON("custom"), "overrides": mustJSON(map[string]any{"proxy-providers": map[string]any{"Feed": map[string]any{"filter": "HK"}}})}, "{}", 0)
	if err != nil {
		t.Fatal(err)
	}
	c := authoring.Empty()
	c["proxyGroups"] = []authoring.Object{authoringRow(map[string]any{"id": 1, "profileId": "custom", "name": "Proxy", "type": "select", "use": []string{"Feed"}, "use-position": map[string]int{"Feed": 0}})}
	if err = r.ReplaceAuthoring(ctx, c, r.Snapshot().Revision); err != nil {
		t.Fatal(err)
	}
	updated, err := r.UpdateMetadata(ctx, "feed", Object{"label": mustJSON("Renamed")}, provider.Revision)
	if err != nil {
		t.Fatal(err)
	}
	group := r.AuthoringSnapshot().Collections["proxyGroups"][0]
	if string(group["use"]) != `["Renamed"]` || string(group["use-position"]) != `{"Renamed":0}` {
		t.Fatal("renaming broke provider references", group)
	}
	custom, _ := r.Get("custom")
	if !strings.Contains(string(custom.Metadata["overrides"]), `"Renamed"`) {
		t.Fatal("renaming broke provider options")
	}
	if err = r.Delete("feed", updated.Revision); err != nil {
		t.Fatal(err)
	}
	if string(r.AuthoringSnapshot().Collections["proxyGroups"][0]["use"]) != `[]` {
		t.Fatal("provider deletion left dangling use")
	}
}
