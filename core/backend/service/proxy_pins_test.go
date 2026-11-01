package service

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"core/backend/profiles"
)

func TestLostFallbackPinReconciliationPreservesNewerSelection(t *testing.T) {
	for _, newer := range []bool{false, true} {
		t.Run(map[bool]string{false: "lost-pin", true: "newer-user-choice"}[newer], func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			request(t, app, "put", "profile.put", map[string]any{"metadata": map[string]any{"id": "p", "selectedMap": map[string]string{"fallback": "a"}}, "source": "proxy-groups: [{name: fallback, type: fallback, proxies: [a, b]}]\nrules: ['MATCH,DIRECT']", "select": true})
			waitDomain(t, app, "put")
			request(t, app, "start", "runtime.start", nil)
			waitRuntime(t, app, "start")
			app.reconcileProxyPins(context.Background(), func(ctx context.Context) (map[string]string, error) {
				if newer {
					record, err := app.profiles.Get("p")
					if err != nil {
						t.Fatal(err)
					}
					_, err = app.profiles.UpdateMetadata(ctx, "p", profiles.Object{"selectedMap": jsonValue(map[string]string{"fallback": "b"})}, record.Revision)
					if err != nil {
						t.Fatal(err)
					}
				}
				return map[string]string{"fallback": ""}, nil
			})
			record, err := app.profiles.Get("p")
			if err != nil {
				t.Fatal(err)
			}
			var selected map[string]string
			_ = json.Unmarshal(record.Metadata["selectedMap"], &selected)
			if newer && selected["fallback"] != "b" {
				t.Fatal("late reconciliation overwrote user choice", selected)
			}
			if !newer && selected["fallback"] != "" {
				t.Fatal("lost pin remained saved", selected)
			}
		})
	}
}
