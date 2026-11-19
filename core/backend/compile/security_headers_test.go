package compile

import "testing"

func TestSpecialHeadersAreEnforcedByBackend(t *testing.T) {
	for _, prefix := range []string{"flclashm-", "flclashx-"} {
		patch := Object{"mode": "global", "mixed-port": 7890}
		SecurityPolicy{}.ApplyPatch(patch, Object{"providerHeaders": Object{prefix + "special": " NOGLOBAL, androidsecure "}}, Capabilities{Platform: "android"})
		if patch["mode"] != "rule" || patch["mixed-port"] != 0 {
			t.Fatal(patch)
		}
	}
	patch := Object{"mode": "global", "mixed-port": 7890}
	SecurityPolicy{}.ApplyPatch(patch, Object{"providerHeaders": Object{"flclashm-special": "", "flclashx-special": "noglobal,androidsecure", "flclashm-androidsecure": "true"}}, Capabilities{Platform: "android"})
	if patch["mode"] != "global" || patch["mixed-port"] != 7890 {
		t.Fatal("explicit modern header must win", patch)
	}
}

func TestOnlyTunDisablesOnlyAndroidSystemProxy(t *testing.T) {
	for _, tc := range []struct {
		name, platform string
		headers        Object
		wantProxy      bool
	}{
		{"Android", "android", Object{"flclashx-special": "onlytun"}, false},
		{"desktop", "linux", Object{"flclashx-special": "onlytun"}, true},
		{"header removed", "android", Object{"flclashx-special": "hideip"}, true},
		{"modern prefix", "android", Object{"flclashm-special": "", "flclashx-special": "onlytun"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			vpn := Object{"enable": true, "systemProxy": true}
			SecurityPolicy{}.ApplyVPN(vpn, Object{"providerHeaders": tc.headers}, Capabilities{Platform: tc.platform})
			if vpn["systemProxy"] != tc.wantProxy || vpn["enable"] != true {
				t.Fatal(vpn)
			}
		})
	}
}
