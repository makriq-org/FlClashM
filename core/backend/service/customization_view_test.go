package service

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"core/backend/profiles"
)

func TestModernAppearancePersistsWithEitherPrefix(t *testing.T) {
	for _, prefix := range []string{"flclashm-", "flclashx-"} {
		t.Run(prefix, func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			metadata := profiles.Object{"providerHeaders": jsonValue(map[string]string{
				prefix + "view":     "proxies.type:tab;proxies.icon:plain;proxies.card:compact;app.board:extended;app.navbar:docked;app.tabs:fade;app.glass:ultra;app.color:123456;app.style:soft;app.black:true",
				prefix + "settings": "openlogs,closeconnections",
				prefix + "widgets":  "profiles,proxyGroups",
			})}
			if err := app.customize(context.Background(), metadata, false); err != nil {
				t.Fatal(err)
			}
			read := func(key string) map[string]any {
				var value map[string]any
				if err := json.Unmarshal(app.Snapshot().Catalog.Settings[key], &value); err != nil {
					t.Fatal(err)
				}
				return value
			}
			theme := read("themeProps")
			if theme["style"] != "enhanced" || theme["liquidGlass"] != "ultra" || theme["primaryColor"] != float64(0xff123456) || theme["pureBlack"] != true || theme["colorStyle"] != "soft" {
				t.Fatal(theme)
			}
			style := read("proxiesStyle")
			if style["type"] != "tab" || style["iconStyle"] != "plain" || style["cardType"] != "compact" {
				t.Fatal(style)
			}
			settings := read("appSetting")
			if settings["floatingNavigationBar"] != false || settings["tabAnimation"] != "fade" || settings["openLogs"] != true || settings["closeConnections"] != true {
				t.Fatal(settings)
			}
			widgets, _ := json.Marshal(settings["dashboardWidgets"])
			if string(widgets) != `["profiles","proxyGroups"]` {
				t.Fatal(settings)
			}
			if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"ownedSettings": []string{"view.app.glass"}})}, 0); err != nil {
				t.Fatal(err)
			}
			metadata["providerHeaders"] = jsonValue(map[string]string{"flclashx-view": "app.glass:none;app.black:false", "flclashm-view": "app.glass:standard;app.black:true;app.color:invalid"})
			if err := app.customize(context.Background(), metadata, false); err != nil {
				t.Fatal(err)
			}
			theme = read("themeProps")
			if theme["liquidGlass"] != "ultra" || theme["pureBlack"] != true || theme["primaryColor"] != float64(0xff123456) {
				t.Fatal("priority, ownership or invalid value", theme)
			}
		})
	}
}
