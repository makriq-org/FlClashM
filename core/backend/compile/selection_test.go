package compile

import (
	"context"
	"encoding/json"
	"testing"

	"core/backend"
)

func TestSelectionReusesValidatedPlanWithoutNetworkOrParser(t *testing.T) {
	validations := 0
	c := Compiler{Validate: func(context.Context, Object) error { validations++; return nil }}
	old := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "rules: ['MATCH,DIRECT']", Metadata: Object{"selectedMap": Object{"Pick": "DIRECT"}}}, Settings: Object{}}
	before, _ := json.Marshal(old)
	plan, err := c.Compile(context.Background(), before, 1)
	if err != nil {
		t.Fatal(err)
	}
	old.CatalogRevision++
	old.Profile.Revision++
	old.Profile.Metadata["selectedMap"] = Object{"Pick": "REJECT"}
	after, _ := json.Marshal(old)
	next, err := c.CompileSelection(context.Background(), after, before, plan, 2)
	if err != nil || next == nil {
		t.Fatal(next, err)
	}
	var result Prepared
	_ = json.Unmarshal(next.Payload(), &result)
	if result.Selected["Pick"] != "REJECT" || validations != 1 || next.Generation() != 2 {
		t.Fatalf("selection did not reuse validation: %#v, %d", result.Selected, validations)
	}
	for _, change := range []func(){
		func() { old.Profile.Text += "\nipv6: false" },
		func() { old.Settings["overrideDns"] = true },
	} {
		change()
		modified, _ := json.Marshal(old)
		if reused, err := c.CompileSelection(context.Background(), modified, before, plan, 3); err != nil || reused != nil {
			t.Fatalf("changed source/settings reused old validation: %v %v", reused, err)
		}
	}
	var original Prepared
	_ = json.Unmarshal(plan.Payload(), &original)
	if original.Selected["Pick"] != "DIRECT" {
		t.Fatal("committed plan mutated")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = c.CompileSelection(ctx, after, before, plan, 3); err == nil {
		t.Fatal("cancellation ignored")
	}
	// Old persisted plans must acquire the corrected engine schema on upgrade.
	delete(original.Config, "rules")
	legacy, _ := backend.NewRuntimePlan(1, original)
	if reused, err := c.CompileSelection(context.Background(), after, before, legacy, 4); err != nil || reused != nil {
		t.Fatal("legacy plan was reused")
	}
}
