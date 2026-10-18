package profiles

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestLegacyAccessControlAndPresentationMigration(t *testing.T) {
	legacy := []byte(`{"profiles":[],"vpnProps":{"enable":true},"accessControl":{"mode":"acceptSelected","acceptList":["com.example.app"],"future":17},"isAccessControl":true,"proxiesStyle":{"iconStyle":"standard","future":"kept"},"unknown":9007199254740993}`)
	r, err := Open(t.TempDir(), func(context.Context, string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if err = r.Migrate(context.Background(), legacy, nil); err != nil {
		t.Fatal(err)
	}
	var vpn Object
	_ = json.Unmarshal(r.Snapshot().Settings["vpnProps"], &vpn)
	var access Object
	_ = json.Unmarshal(vpn["accessControl"], &access)
	if string(access["enable"]) != "true" || string(access["future"]) != "17" {
		t.Fatal(access)
	}
	var style Object
	_ = json.Unmarshal(r.Snapshot().Settings["proxiesStyle"], &style)
	if string(style["iconStyle"]) != `"icon"` || string(style["future"]) != `"kept"` || string(r.Snapshot().Settings["unknown"]) != "9007199254740993" {
		t.Fatal(style)
	}
	if !strings.Contains(string(legacy), `"iconStyle":"standard"`) {
		t.Fatal("migration changed original legacy data")
	}
}
