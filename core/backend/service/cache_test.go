package service

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"core/backend"
	"core/backend/authoring"
)

type cacheEngine struct {
	testEngine
	commandMu sync.Mutex
	commands  []backend.EngineCommand
	fail      bool
}

func (e *cacheEngine) Command(ctx context.Context, command backend.EngineCommand) error {
	e.commandMu.Lock()
	defer e.commandMu.Unlock()
	e.commands = append(e.commands, command)
	if e.fail {
		return errors.New("cache effect failed")
	}
	return ctx.Err()
}
func TestCacheCommandsUseCoordinatorAndPreserveDomainData(t *testing.T) {
	engine := &cacheEngine{}
	opts := options(t, t.TempDir(), &engine.testEngine, make(chan time.Time))
	opts.Engine = engine
	app := openTestApp(t, opts)
	waitCondition(t, func() bool { return len(app.profiles.Snapshot().Settings["patchClashConfig"]) > 0 })
	request(t, app, "add-cache-profile", "profile.put", map[string]any{"metadata": map[string]any{"id": "profile:string", "type": "custom", "label": "Custom"}})
	waitDomain(t, app, "add-cache-profile")
	snapshot := authoringRequest(t, app)
	snapshot.Collections["scripts"] = []authoring.Object{collectionRow(map[string]any{"id": 1, "label": "Script", "content": "function main(c){return c}"})}
	request(t, app, "cache-declarations", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "collections": snapshot.Collections})
	waitDomain(t, app, "cache-declarations")
	before := app.profiles.Snapshot()
	for _, item := range []struct {
		id, method string
		params     any
	}{{"clear-all", "storage.clearCache", map[string]any{}}, {"collect", "storage.collect", map[string]any{}}, {"clear-profile", "profile.clearCache", map[string]any{"profileId": "profile:string"}}} {
		request(t, app, item.id, item.method, item.params)
		receipt := waitDomain(t, app, item.id)
		if receipt.RuntimeOperationID == "" {
			t.Fatal("cache effect bypassed coordinator", receipt)
		}
	}
	if !reflect.DeepEqual(before, app.profiles.Snapshot()) {
		t.Fatal("cache command erased profiles/settings/authoring")
	}
	engine.commandMu.Lock()
	commands := append([]backend.EngineCommand(nil), engine.commands...)
	engine.fail = true
	engine.commandMu.Unlock()
	if len(commands) != 3 || commands[0].Method != "cache.clear" || commands[1].Method != "cache.collect" || commands[2].Method != "cache.clear" {
		t.Fatal("incorrect cache adapter contract", commands)
	}
	var params map[string]string
	_ = json.Unmarshal(commands[2].Params, &params)
	if params["profileId"] != "profile:string" {
		t.Fatal("profile cache lost string id", params)
	}
	request(t, app, "failed-cache", "storage.clearCache", map[string]any{})
	failed, err := app.Await(context.Background(), "failed-cache")
	if err != nil || failed.Status != "failed" {
		t.Fatal("cache failure reported success", failed, err)
	}
}
func TestAuthoringAtomicLastDeletionStopsRunningRuntime(t *testing.T) {
	app, _ := testAuthoringApp(t)
	snapshot := authoringRequest(t, app)
	request(t, app, "create-atomic", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "profiles": []any{map[string]any{"id": "atomic:string", "type": "custom", "label": "Atomic", "opaque": "keep"}}, "collections": snapshot.Collections})
	waitDomain(t, app, "create-atomic")
	request(t, app, "select-atomic", "profile.select", map[string]any{"profileId": "atomic:string"})
	waitDomain(t, app, "select-atomic")
	request(t, app, "start-atomic", "runtime.start", nil)
	waitRuntime(t, app, "start-atomic")
	snapshot = authoringRequest(t, app)
	before := app.profiles.Snapshot()
	request(t, app, "stale-delete-atomic", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision - 1, "deletedProfileIds": []string{"atomic:string"}, "profiles": []any{map[string]any{"id": "never", "type": "custom"}}, "collections": snapshot.Collections})
	failed, err := app.Await(context.Background(), "stale-delete-atomic")
	if err != nil || failed.ErrorCode != "conflict" || !reflect.DeepEqual(before, app.profiles.Snapshot()) {
		t.Fatal("CAS failure partially changed data", failed, err)
	}
	request(t, app, "delete-atomic", "authoring.replace", map[string]any{"expectedRevision": snapshot.Revision, "deletedProfileIds": []string{"atomic:string"}, "collections": snapshot.Collections})
	removed := waitDomain(t, app, "delete-atomic")
	if removed.RuntimeOperationID == "" || len(app.Snapshot().Catalog.Profiles) != 0 || app.Snapshot().Runtime.DesiredRunning {
		t.Fatal("last atomic deletion did not stop runtime", removed, app.Snapshot())
	}
}
