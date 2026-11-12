package service

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

type presentationInspection struct {
	testNodeMechanism
	selected map[string]string
}

// Selected returns only the groups requested, like the engine inspection adapter.
func (p presentationInspection) Selected(_ context.Context, groups []string) (map[string]string, error) {
	result := map[string]string{}
	for _, group := range groups {
		result[group] = p.selected[group]
	}
	return result, nil
}

// TestPresentationFollowsAppliedMode covers transitions with saved and live nodes.
func TestPresentationFollowsAppliedMode(t *testing.T) {
	for _, header := range []string{"", "Preferred", "GLOBAL"} {
		for _, observed := range []bool{false, true} {
			t.Run(fmt.Sprintf("header=%s/observed=%t", header, observed), func(t *testing.T) {
				opt := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
				if observed {
					opt.Nodes.Inspection = presentationInspection{selected: map[string]string{
						"GLOBAL": "Manual", "Rules": "Auto", "Auto": "Live", "Preferred": "Advised",
					}}
				}
				app := openTestApp(t, opt)
				request(t, app, "put", "profile.put", map[string]any{
					"metadata": map[string]any{"id": "one", "label": "Profile",
						"providerHeaders": map[string]string{"flclashm-serverinfo": header},
						"selectedMap":     map[string]string{"Rules": "Auto", "Auto": "Saved", "Preferred": "Advised"}},
					"source": `proxies: [{name: Manual, type: direct}, {name: Saved, type: direct}, {name: Live, type: direct}, {name: Advised, type: direct}]
proxy-groups:
 - {name: Rules, type: select, proxies: [Auto]}
 - {name: Auto, type: url-test, proxies: [Saved, Live], url: 'https://example.com', interval: 300}
 - {name: Preferred, type: select, proxies: [Advised]}
rules: ['MATCH,Rules']`, "select": true,
				})
				waitDomain(t, app, "put")
				for step, mode := range []string{"global", "rule", "direct", "global", "DIRECT", "GLOBAL", "RuLe"} {
					id := fmt.Sprintf("mode-%d", step)
					request(t, app, id, "settings.patch", map[string]any{"patch": map[string]any{"patchClashConfig": map[string]any{"mode": mode}}})
					receipt := waitDomain(t, app, id)
					waitRuntime(t, app, receipt.RuntimeOperationID)
					if strings.EqualFold(mode, "global") {
						request(t, app, id+"-select", "proxy.select", map[string]any{"group": "GLOBAL", "proxy": "Manual"})
						receipt = waitDomain(t, app, id+"-select")
						waitRuntime(t, app, receipt.RuntimeOperationID)
					}
					want := "Profile"
					switch strings.ToLower(mode) {
					case "global":
						want += " / Manual"
					case "rule":
						if header == "Preferred" {
							want += " / Advised"
						} else if observed {
							want += " / Live"
						} else {
							want += " / Saved"
						}
					}
					got := app.Presentation()
					if got.Mode != mode || got.NotificationTitle != want {
						t.Fatalf("mode %s: got %+v, want title %q", mode, got, want)
					}
				}
			})
		}
	}
}

// TestRulePresentationDoesNotFallBackToGlobal excludes an unused saved selection.
func TestRulePresentationDoesNotFallBackToGlobal(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	request(t, app, "put", "profile.put", map[string]any{
		"metadata": map[string]any{"id": "one", "label": "Profile", "selectedMap": map[string]string{"GLOBAL": "Manual"}},
		"source":   "rules: ['MATCH,DIRECT']", "select": true,
	})
	receipt := waitDomain(t, app, "put")
	waitRuntime(t, app, receipt.RuntimeOperationID)
	if got := app.Presentation(); got.NotificationTitle != "Profile" {
		t.Fatal("rule mode displayed inactive GLOBAL selection", got)
	}
}

// TestRulePresentationGlobalTargets checks references in the applied rule graph.
func TestRulePresentationGlobalTargets(t *testing.T) {
	for _, tc := range []struct {
		name       string
		rules      []string
		subRules   map[string][]string
		wantGlobal bool
	}{
		{name: "match", rules: []string{"MATCH,GLOBAL"}, wantGlobal: true},
		{name: "parameters", rules: []string{"IP-CIDR,192.0.2.0/24,GLOBAL,no-resolve", "MATCH,Rules"}, wantGlobal: true},
		{name: "logical", rules: []string{"AND,((NETWORK,TCP),(DST-PORT,443)),GLOBAL", "MATCH,Rules"}, wantGlobal: true},
		{name: "payload", rules: []string{"DOMAIN,GLOBAL,Rules", "MATCH,Rules"}},
		{name: "unused-section", rules: []string{"MATCH,Rules"}, subRules: map[string][]string{"unused": {"MATCH,GLOBAL"}}},
		{name: "nested", rules: []string{"SUB-RULE,(NETWORK,TCP),outer", "MATCH,Rules"}, subRules: map[string][]string{
			"outer": {"SUB-RULE,(DST-PORT,443),inner"}, "inner": {"MATCH,GLOBAL"},
		}, wantGlobal: true},
		{name: "section-named-global", rules: []string{"SUB-RULE,(NETWORK,TCP),GLOBAL", "MATCH,Rules"}, subRules: map[string][]string{"GLOBAL": {"MATCH,Rules"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			source, err := json.Marshal(map[string]any{
				"proxies":      []any{map[string]any{"name": "Manual", "type": "direct"}, map[string]any{"name": "Saved", "type": "direct"}},
				"proxy-groups": []any{map[string]any{"name": "Rules", "type": "select", "proxies": []string{"Saved"}}},
				"rules":        tc.rules, "sub-rules": tc.subRules,
			})
			if err != nil {
				t.Fatal(err)
			}
			request(t, app, "put", "profile.put", map[string]any{
				"metadata": map[string]any{"id": "one", "label": "Profile", "selectedMap": map[string]string{"GLOBAL": "Manual", "Rules": "Saved"}},
				"source":   string(source), "select": true,
			})
			receipt := waitDomain(t, app, "put")
			waitRuntime(t, app, receipt.RuntimeOperationID)
			want := "Profile / Saved"
			if tc.wantGlobal {
				want = "Profile / Manual"
			}
			if got := app.Presentation(); got.NotificationTitle != want {
				t.Fatalf("got %+v, want %q", got, want)
			}
		})
	}
}
