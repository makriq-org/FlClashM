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
