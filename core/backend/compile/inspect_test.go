package compile

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
)

func TestInspectCustomProfileReportsPackageRules(t *testing.T) {
	compiler := Compiler{Capabilities: Capabilities{Platform: "android", SelfPackages: []string{"com.makriq.flclash"}}}
	input := Input{Version: 1, Profile: &RawProfile{ID: "custom:1", Metadata: Object{
		"type": "custom",
		"customConfig": Object{
			"tun": Object{"exclude-package": []any{"com.example.private"}},
		},
	}}}
	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	inspection, err := compiler.InspectProfile(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	access := object(inspection.AccessControl)
	if access["mode"] != "rejectSelected" || access["enable"] != true {
		t.Fatalf("missing custom profile access: %#v", access)
	}
	rejected := list(access["rejectList"])
	for _, name := range []string{"com.example.private", "com.makriq.flclash"} {
		found := false
		for _, value := range rejected {
			found = found || value == name
		}
		if !found {
			t.Fatalf("rejected package %s missing: %#v", name, rejected)
		}
	}
	if !reflect.DeepEqual(object(inspection.Config["tun"])["exclude-package"], []any{"com.example.private"}) {
		t.Fatalf("inspection mutated custom config: %#v", inspection.Config["tun"])
	}
}
