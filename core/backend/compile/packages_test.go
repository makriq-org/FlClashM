package compile

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

type packageListFunc func(context.Context, string, string) (string, error)

func (f packageListFunc) Read(ctx context.Context, id, address string) (string, error) {
	return f(ctx, id, address)
}
func TestAndroidPackageSelectorsAndPrivateSources(t *testing.T) {
	inventoryReads := 0
	compiler := Compiler{Capabilities: Capabilities{Platform: "android", InstalledPackages: func(context.Context) ([]string, error) {
		inventoryReads++
		return []string{"com.example.one", "com.example.two", "com.makriq.flclash", "org.sample"}, nil
	}}, Lists: packageListFunc(func(ctx context.Context, id, address string) (string, error) {
		if id != "p" || address != "http://192.168.1.1/packages" {
			t.Fatalf("source: %s %s", id, address)
		}
		return "# comment\ncom.example.*\n!com.example.two\nre:^(?=org\\.)org.sample$\n", nil
	}), Validate: func(context.Context, Object) error { return nil }}
	request := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: `tun:
 include-package: [com.example.two]
 include-package-file: [{path: /private/list, url: 'http://192.168.1.1/packages'}]
`}, Settings: Object{}}
	p := prepared(t, compiler, request)
	access := object(object(p.CoreState["vpn-props"])["accessControl"])
	if !reflect.DeepEqual(access["acceptList"], []any{"com.example.one", "org.sample"}) || inventoryReads != 1 {
		t.Fatalf("selector order %#v reads=%d", access, inventoryReads)
	}
	tun := object(p.Config["tun"])
	if tun["include-package-file"] != nil || !reflect.DeepEqual(tun["include-package"], []any{"com.example.one", "org.sample"}) || len(p.Diagnostics) != 1 {
		t.Fatalf("source normalization: %#v %v", tun, p.Diagnostics)
	}
	request.Profile.Text = "tun: {include-package: [com.future.app]}"
	p = prepared(t, compiler, request)
	if inventoryReads != 1 || !reflect.DeepEqual(object(p.Config["tun"])["include-package"], []any{"com.future.app"}) {
		t.Fatal("literal selector should not require inventory")
	}
	request.Profile.Text = "tun: {include-package: [com.one], exclude-package: [com.two]}"
	raw := []byte(`{"version":1,"profile":{"id":"p","text":"` + request.Profile.Text + `"},"settings":{}}`)
	if _, err := compiler.Compile(context.Background(), raw, 1); err == nil {
		t.Fatal("ambiguous include/exclude accepted")
	}
	compiler.Lists = packageListFunc(func(context.Context, string, string) (string, error) { return "", errors.New("offline") })
	request.Profile.Text = "tun: {include-package-url: 'https://example.com/list'}"
	raw = []byte(`{"version":1,"profile":{"id":"p","text":"` + request.Profile.Text + `"},"settings":{}}`)
	if _, err := compiler.Compile(context.Background(), raw, 1); err == nil {
		t.Fatal("required package source failure ignored")
	}
}
func TestOwnedAccessControlKeepsManualRules(t *testing.T) {
	compiler := Compiler{
		Capabilities: Capabilities{
			Platform:     "android",
			SelfPackages: []string{"com.makriq.flclash"},
		},
		Validate: func(context.Context, Object) error { return nil },
	}
	profile := &RawProfile{ID: "p", Text: "tun: {include-package: [com.example.one]}"}
	settings := Object{
		"appSetting": Object{"ownedSettings": []any{AccessControlSettingKey}},
		"vpnProps": Object{
			"accessControl": Object{
				"enable":     true,
				"mode":       "rejectSelected",
				"rejectList": []any{"com.manual"},
			},
		},
	}

	p := prepared(t, compiler, Input{Version: 1, Profile: profile, Settings: settings})
	access := object(object(p.CoreState["vpn-props"])["accessControl"])
	if !reflect.DeepEqual(access["rejectList"], []any{"com.manual", "com.makriq.flclash"}) {
		t.Fatalf("manual rules were replaced: %#v", access)
	}
	if p.ProfileAccessControl != nil {
		t.Fatalf("owned profile rules leaked into the plan: %#v", p.ProfileAccessControl)
	}
	if object(p.Config["tun"])["include-package"] != nil {
		t.Fatalf("profile package rules stayed in the engine config: %#v", p.Config["tun"])
	}

	settings["appSetting"] = Object{}
	p = prepared(t, compiler, Input{Version: 1, Profile: profile, Settings: settings})
	access = object(object(p.CoreState["vpn-props"])["accessControl"])
	if !reflect.DeepEqual(access["acceptList"], []any{"com.example.one"}) || p.ProfileAccessControl == nil {
		t.Fatalf("profile rules stopped applying without ownership: %#v", access)
	}
}

func TestCustomInspectionReportsDeclaredAccessControl(t *testing.T) {
	compiler, request := customRequest(t)
	request.Profile.Metadata["customConfig"] = Object{
		"tun": Object{"include-package": []any{"com.example.one"}},
	}
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	inspection, err := compiler.InspectProfile(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	access := object(inspection.AccessControl)
	if !reflect.DeepEqual(access["acceptList"], []any{"com.example.one"}) {
		t.Fatalf("custom profile rules were not inspected: %#v", access)
	}
}

func TestBundledAutoStrategyAndLegacyAliases(t *testing.T) {
	source := `proxies: [{name: Bye, type: byedpi, selection: {concurrency: 2, foreground-timeout: 10s, background: false}, strategy-test: {resolver: system, concurrency: 3}}]`
	nodes, err := (&ExternalCompiler{}).Compile(context.Background(), mustProfile(t, source), defaults(), "")
	if err != nil {
		t.Fatal(err)
	}
	body := nodes[0].Files["built-in-proxies/byedpi/"+nodes[0].ID+"/config.json"]
	if !strings.Contains(body, `"foreground-timeout":10`) || !strings.Contains(body, `"background":false`) || !strings.Contains(body, `"resolver":"system"`) {
		t.Fatalf("legacy aliases: %s", body)
	}
	if !strings.Contains(body, `"strategies":[`) {
		t.Fatal("bundled strategy list missing")
	}
}

func TestPackageInventoryFailureCannotSilentlyDiscardSplitTunneling(t *testing.T) {
	for _, inventory := range []func(context.Context) ([]string, error){
		nil,
		func(context.Context) ([]string, error) { return nil, errors.New("permission denied") },
		func(context.Context) ([]string, error) { return []string{}, nil },
	} {
		compiler := Compiler{Capabilities: Capabilities{Platform: "android", InstalledPackages: inventory}}
		config := mustProfile(t, "tun: {exclude-package: ['com.example.*']}")
		diagnostics := []string{}
		if _, err := compiler.splitPackages(context.Background(), config, "p", &diagnostics); err == nil {
			t.Fatal("unavailable inventory silently changed the VPN package policy")
		}
	}
}

func TestRemotePackageYAMLListKeepsTaggedExclusions(t *testing.T) {
	parsed, err := parsePackageBody("- com.example.*\n- !com.example.two\n- org.sample # note\n")
	if err != nil {
		t.Fatal(err)
	}
	var raw []string
	for _, s := range parsed {
		raw = append(raw, s.raw)
	}
	if !reflect.DeepEqual(raw, []string{"com.example.*", "!com.example.two", "org.sample"}) {
		t.Fatal("YAML-list exclusion was lost", raw)
	}
	// Ordinary YAML lists keep YAML scalar handling.
	parsed, err = parsePackageBody("- 'com.example.one'\n- \"!com.example.two\"\n")
	if err != nil || len(parsed) != 2 || parsed[1].include || parsed[0].raw != "com.example.one" {
		t.Fatal("plain YAML list changed", parsed, err)
	}
	compiler := Compiler{Capabilities: Capabilities{Platform: "android", InstalledPackages: func(context.Context) ([]string, error) {
		return []string{"com.example.one", "com.example.two", "org.sample"}, nil
	}}, Lists: packageListFunc(func(context.Context, string, string) (string, error) {
		return "- com.example.*\n- !com.example.two\n", nil
	}), Validate: func(context.Context, Object) error { return nil }}
	p := prepared(t, compiler, Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "tun: {include-package-url: 'https://example.com/list'}"}, Settings: Object{}})
	access := object(object(p.CoreState["vpn-props"])["accessControl"])
	if !reflect.DeepEqual(access["acceptList"], []any{"com.example.one"}) {
		t.Fatal("remote exclusion ignored", access)
	}
}
