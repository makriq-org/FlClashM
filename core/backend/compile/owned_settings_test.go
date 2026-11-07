package compile

import (
	"context"
	"testing"
)

func TestUserOwnedNetworkSettingsSurviveProviderAndSecurity(t *testing.T) {
	c := Compiler{Validate: func(context.Context, Object) error { return nil }}
	input := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "ipv6: true\nfind-process-mode: always\ntun: {stack: system}\nauthentication: ['provider:secret']"}, Settings: Object{
		"appSetting":       Object{"ownedSettings": []any{"clash.ipv6", "clash.find-process-mode", "clash.tun.stack", "clash.authentication"}},
		"patchClashConfig": Object{"ipv6": false, "find-process-mode": "strict", "tun": Object{"stack": "gvisor"}},
		"networkProps":     Object{"authentication": Object{"enable": true, "username": "user", "password": "pass:word"}},
	}}
	result := prepared(t, c, input)
	if result.Config["ipv6"] != false || result.Config["find-process-mode"] != "strict" || object(result.Config["tun"])["stack"] != "gvisor" {
		t.Fatalf("provider overrode user settings: %#v", result.Patch)
	}
	if got := list(result.Config["authentication"]); len(got) != 1 || got[0] != "user:pass:word" {
		t.Fatal("user credentials were not retained", got)
	}
	delete(object(input.Settings["appSetting"]), "ownedSettings")
	result = prepared(t, c, input)
	if result.Config["ipv6"] != true || result.Config["find-process-mode"] != "always" || list(result.Config["authentication"])[0] != "provider:secret" {
		t.Fatal("returning ownership did not restore provider values", result.Config)
	}
}

func TestInspectionAuthenticationPreservesPasswordColons(t *testing.T) {
	result, err := (&Compiler{}).Inspect(context.Background(), "authentication: ['invalid', 'user:pass:word']", "p")
	if err != nil || result.Authentication["enable"] != true || result.Authentication["username"] != "user" || result.Authentication["password"] != "pass:word" {
		t.Fatal(result.Authentication, err)
	}
}
