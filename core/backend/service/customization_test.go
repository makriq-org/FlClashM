package service

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"core/backend/profiles"
)

func TestProviderCustomizationPersistsWithoutUI(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"overrideProviderSettings": true, "autoRun": false}), "themeProps": jsonValue(map[string]any{"primaryColors": []uint64{0xFF03A9F4}, "schemeVariant": "neutral", "futureTheme": "preserve"})}, 0); err != nil {
		t.Fatal(err)
	}
	metadata := profiles.Object{"providerHeaders": jsonValue(map[string]string{"flclashm-custom": "update", "flclashm-settings": "autostart,autoupdate", "flclashm-hex": "#ABCDEF:vibrant:pureblack", "flclashm-widgets": "outboundModeV2,trafficUsage,unknown", "flclashm-view": "type:tab;sort:delay;icon:standard;card:oneline"})}
	if err := app.customize(context.Background(), metadata, false); err != nil {
		t.Fatal(err)
	}
	catalog := app.Snapshot().Catalog
	var settings map[string]any
	_ = json.Unmarshal(catalog.Settings["appSetting"], &settings)
	if settings["autoRun"] != false {
		t.Fatal("user override ignored", settings)
	}
	var theme map[string]any
	_ = json.Unmarshal(catalog.Settings["themeProps"], &theme)
	if theme["primaryColor"] != float64(0xFFABCDEF) || theme["pureBlack"] != true || theme["schemeVariant"] != "vibrant" || theme["futureTheme"] != "preserve" {
		t.Fatal("theme projection", theme)
	}
	var style map[string]any
	_ = json.Unmarshal(catalog.Settings["proxiesStyle"], &style)
	if style["type"] != "tab" || style["iconStyle"] != "icon" || style["cardType"] != "oneline" {
		t.Fatal(style)
	}
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"overrideProviderSettings": false})}, 0); err != nil {
		t.Fatal(err)
	}
	if err := app.customize(context.Background(), metadata, false); err != nil {
		t.Fatal(err)
	}
	_ = json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings)
	if settings["autoRun"] != true || settings["autoCheckUpdate"] != true || settings["silentLaunch"] != false {
		t.Fatal("provider settings", settings)
	}
	if err := app.patchSettings(context.Background(), profiles.Object{"sendDeviceHeaders": jsonValue(false)}, 0); err != nil {
		t.Fatal(err)
	}
	if app.deviceHeadersRequested(nil) || app.deviceHeadersEnabled(true) {
		t.Fatal("device-header setting ignored")
	}
}
