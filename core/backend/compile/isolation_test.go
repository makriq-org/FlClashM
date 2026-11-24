package compile

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func isolationCompiler() Compiler {
	return Compiler{
		Capabilities: Capabilities{Platform: "android", HomeDir: "/home/test", ProfilesDir: "/home/test/profiles"},
		Validate:     func(context.Context, Object) error { return nil },
	}
}

func appIsolation(t *testing.T, result Prepared) Object {
	t.Helper()
	raw, ok := result.CoreState["app-isolation"]
	if !ok {
		t.Fatal("core state has no app-isolation")
	}
	return object(raw)
}

func TestAppIsolationDefaultsToBalanced(t *testing.T) {
	result := prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {enable: true}"}, Settings: Object{}})
	state := appIsolation(t, result)
	if state["mode"] != "balanced" || state["source"] != "default" {
		t.Fatalf("state = %#v", state)
	}
	if _, present := object(result.Config["tun"])["app-isolation"]; present {
		t.Fatal("client setting leaked into the engine config")
	}
	if _, present := object(result.Patch["tun"])["app-isolation"]; present {
		t.Fatal("client setting leaked into the resolved patch")
	}
}

func TestAppIsolationProfileValue(t *testing.T) {
	result := prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {enable: true, app-isolation: strict}"}, Settings: Object{}})
	state := appIsolation(t, result)
	if state["mode"] != "strict" || state["source"] != "profile" {
		t.Fatalf("state = %#v", state)
	}
}

func TestAppIsolationLocalSettingWinsWhenProfileSilent(t *testing.T) {
	settings := Object{"patchClashConfig": Object{"tun": Object{"app-isolation": "off"}}}
	result := prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {enable: true}"}, Settings: settings})
	state := appIsolation(t, result)
	if state["mode"] != "off" || state["source"] != "user" {
		t.Fatalf("state = %#v", state)
	}
}

func TestAppIsolationOwnershipReturnsControlToTheUser(t *testing.T) {
	settings := Object{
		"appSetting":       Object{"ownedSettings": []any{AppIsolationSettingKey}},
		"patchClashConfig": Object{"tun": Object{"app-isolation": "off"}},
	}
	profile := "tun: {enable: true, app-isolation: strict}"
	result := prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: profile}, Settings: settings})
	state := appIsolation(t, result)
	if state["mode"] != "off" || state["source"] != "user" {
		t.Fatalf("taken-over setting = %#v", state)
	}
	delete(object(settings["appSetting"]), "ownedSettings")
	result = prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: profile}, Settings: settings})
	state = appIsolation(t, result)
	if state["mode"] != "strict" || state["source"] != "profile" {
		t.Fatalf("returned setting = %#v", state)
	}
}

func TestAppIsolationNetworkOverrideWinsOverProfile(t *testing.T) {
	settings := Object{
		"appSetting":       Object{"overrideNetworkSettings": true},
		"patchClashConfig": Object{"tun": Object{"app-isolation": "balanced"}},
	}
	result := prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {app-isolation: strict}"}, Settings: settings})
	state := appIsolation(t, result)
	if state["mode"] != "balanced" || state["source"] != "user" {
		t.Fatalf("state = %#v", state)
	}
}

func TestAppIsolationInvalidProfileValueFailsCompilation(t *testing.T) {
	c := isolationCompiler()
	raw := `{"version":1,"profile":{"id":"p","text":"tun: {app-isolation: paranoid}"},"settings":{}}`
	if _, err := c.Compile(context.Background(), []byte(raw), 1); err == nil || !strings.Contains(err.Error(), "tun.app-isolation") {
		t.Fatalf("error = %v", err)
	}
}

func TestAppIsolationInvalidLocalValueFailsCompilation(t *testing.T) {
	c := isolationCompiler()
	settings := Object{"patchClashConfig": Object{"tun": Object{"app-isolation": "sometimes"}}}
	raw, err := json.Marshal(Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {enable: true}"}, Settings: settings})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = c.Compile(context.Background(), raw, 1); err == nil || !strings.Contains(err.Error(), "tun.app-isolation") {
		t.Fatalf("error = %v", err)
	}
}

func TestAppIsolationIsAndroidOnly(t *testing.T) {
	c := isolationCompiler()
	c.Capabilities.Platform = "windows"
	result := prepared(t, c, Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {app-isolation: strict}"}, Settings: Object{}})
	if _, present := result.CoreState["app-isolation"]; present {
		t.Fatal("non-Android plan carries an Android-only setting")
	}
	if _, present := object(result.Config["tun"])["app-isolation"]; present {
		t.Fatal("client setting leaked into the engine config")
	}
}

func TestAppIsolationValuesCaseAndSpacing(t *testing.T) {
	for _, value := range []string{"OFF", " Balanced ", "strict"} {
		result := prepared(t, isolationCompiler(), Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {app-isolation: '" + value + "'}"}, Settings: Object{}})
		state := appIsolation(t, result)
		want := strings.ToLower(strings.TrimSpace(value))
		if state["mode"] != want {
			t.Fatalf("%q -> %#v", value, state)
		}
	}
}

func TestAppIsolationKeepsSpecialHeaderBehavior(t *testing.T) {
	c := isolationCompiler()
	result := prepared(t, c, Input{
		Version: 1,
		Profile: &RawProfile{
			ID:   "p",
			Text: "mixed-port: 7890\nmode: global\ntun: {app-isolation: strict}\n",
			Metadata: Object{"providerHeaders": Object{
				"flclashx-special":       "onlytun,noglobal,androidsecure",
				"flclashm-androidsecure": "true",
			}},
		},
		Settings: Object{"vpnProps": Object{"systemProxy": true}},
	})
	if got := appIsolation(t, result)["mode"]; got != "strict" {
		t.Fatalf("mode = %v", got)
	}
	vpn := object(result.CoreState["vpn-props"])
	if vpn["systemProxy"] != false {
		t.Fatal("onlytun stopped disabling the system proxy")
	}
	if result.Config["mixed-port"] != float64(0) || result.Config["mode"] != "rule" {
		t.Fatalf("security headers changed: %#v", result.Config)
	}
}

func TestAppIsolationIgnoresAnInvalidProfileValueItDoesNotUse(t *testing.T) {
	for _, tc := range []struct {
		name     string
		settings Object
	}{
		{"owned", Object{"appSetting": Object{"ownedSettings": []any{AppIsolationSettingKey}}}},
		{"override", Object{"appSetting": Object{"overrideNetworkSettings": true}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.settings["patchClashConfig"] = Object{"tun": Object{"app-isolation": "balanced"}}
			result := prepared(t, isolationCompiler(), Input{
				Version:  1,
				Profile:  &RawProfile{ID: "p", Text: "tun: {app-isolation: nonsense}"},
				Settings: tc.settings,
			})
			state := appIsolation(t, result)
			if state["mode"] != "balanced" || state["source"] != "user" {
				t.Fatalf("state = %#v", state)
			}
		})
	}
}

func TestAppIsolationIgnoresAnInvalidLocalValueTheProfileOverrides(t *testing.T) {
	result := prepared(t, isolationCompiler(), Input{
		Version:  1,
		Profile:  &RawProfile{ID: "p", Text: "tun: {app-isolation: strict}"},
		Settings: Object{"patchClashConfig": Object{"tun": Object{"app-isolation": "broken"}}},
	})
	state := appIsolation(t, result)
	if state["mode"] != "strict" || state["source"] != "profile" {
		t.Fatalf("state = %#v", state)
	}
}
