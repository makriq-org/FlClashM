package service

import (
	"encoding/json"
	"testing"
	"time"
)

func TestAppIsolationOwnershipAndLocalValueReapplyRuntime(t *testing.T) {
	engine := &testEngine{}
	app := openTestApp(t, options(t, t.TempDir(), engine, make(chan time.Time)))
	request(t, app, "local", "settings.patch", map[string]any{"patch": map[string]any{
		"patchClashConfig": map[string]any{"tun": map[string]any{"app-isolation": "off"}},
	}})
	waitDomain(t, app, "local")
	request(t, app, "add", "profile.put", map[string]any{
		"metadata": map[string]any{"id": "p"},
		"source":   "tun: {app-isolation: strict}",
		"select":   true,
	})
	waitDomain(t, app, "add")
	request(t, app, "start", "runtime.start", nil)
	waitRuntime(t, app, "start")

	assertMode := func(want string) {
		t.Helper()
		engine.mu.Lock()
		defer engine.mu.Unlock()
		var plan struct {
			CoreState struct {
				AppIsolation struct {
					Mode   string `json:"mode"`
					Source string `json:"source"`
				} `json:"app-isolation"`
			} `json:"coreState"`
		}
		if err := json.Unmarshal(engine.payload, &plan); err != nil {
			t.Fatalf("plan: %v", err)
		}
		if plan.CoreState.AppIsolation.Mode != want {
			t.Fatalf("mode = %s, want %s; payload %s", plan.CoreState.AppIsolation.Mode, want, engine.payload)
		}
	}
	assertMode("strict")

	// Taking the setting over hands control back to the local value.
	request(t, app, "take", "settings.patch", map[string]any{"patch": map[string]any{
		"appSetting": map[string]any{"ownedSettings": []string{"clash.tun.app-isolation"}},
	}})
	receipt := waitDomain(t, app, "take")
	if receipt.RuntimeOperationID == "" {
		t.Fatal("taking the setting over did not schedule a runtime update")
	}
	waitRuntime(t, app, receipt.RuntimeOperationID)
	assertMode("off")

	// A local change while owned applies immediately.
	request(t, app, "local-change", "settings.patch", map[string]any{"patch": map[string]any{
		"patchClashConfig": map[string]any{"tun": map[string]any{"app-isolation": "balanced"}},
	}})
	receipt = waitDomain(t, app, "local-change")
	waitRuntime(t, app, receipt.RuntimeOperationID)
	assertMode("balanced")

	// Returning it to the subscription restores the profile value.
	request(t, app, "release", "settings.patch", map[string]any{"patch": map[string]any{
		"appSetting": map[string]any{"ownedSettings": []string{}},
	}})
	receipt = waitDomain(t, app, "release")
	if receipt.RuntimeOperationID == "" {
		t.Fatal("returning the setting did not schedule a runtime update")
	}
	waitRuntime(t, app, receipt.RuntimeOperationID)
	assertMode("strict")
}
