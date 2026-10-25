package service

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
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
			if err := app.customizeForProfile(context.Background(), metadata, false, true); err != nil {
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
			if err := app.customizeForProfile(context.Background(), metadata, false, true); err != nil {
				t.Fatal(err)
			}
			theme = read("themeProps")
			if theme["liquidGlass"] != "ultra" || theme["pureBlack"] != true || theme["primaryColor"] != float64(0xff123456) {
				t.Fatal("priority, ownership or invalid value", theme)
			}
		})
	}
}

// TestAppearancePaletteAndWidgetsMatchLegacy covers absent palettes and aliases
// through both customization paths, including explicitly empty saved palettes.
func TestAppearancePaletteAndWidgetsMatchLegacy(t *testing.T) {
	for _, custom := range []bool{false, true} {
		for _, saved := range []bool{false, true} {
			t.Run(fmt.Sprintf("custom=%v/saved=%v", custom, saved), func(t *testing.T) {
				app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
				if saved {
					if err := app.patchSettings(context.Background(), profiles.Object{"themeProps": jsonValue(map[string]any{"primaryColors": []uint64{}})}, 0); err != nil {
						t.Fatal(err)
					}
				}
				headers := map[string]string{"flclashm-view": "app.color:123456", "flclashm-widgets": "outboundModeV2,trafficUsage,profiles,outboundModeV2,unknown"}
				if custom {
					headers["flclashm-custom"] = "update"
					headers["flclashm-hex"] = "123456"
				}
				if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(headers)}, false, true); err != nil {
					t.Fatal(err)
				}
				var theme struct {
					Colors []uint64 `json:"primaryColors"`
				}
				if err := json.Unmarshal(app.Snapshot().Catalog.Settings["themeProps"], &theme); err != nil {
					t.Fatal(err)
				}
				expected := []uint64{0xff123456}
				if !saved {
					expected = append(defaultProviderPrimaryColors(), expected...)
				}
				if !reflect.DeepEqual(theme.Colors, expected) {
					t.Fatalf("palette %v, want %v", theme.Colors, expected)
				}
				var settings struct {
					Widgets []string `json:"dashboardWidgets"`
				}
				if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(settings.Widgets, []string{"outboundModeV2", "trafficUsage", "profiles"}) {
					t.Fatal(settings.Widgets)
				}
			})
		}
	}
}

// TestProviderSwitchOwnership applies the same user opt-out to both header paths.
func TestProviderSwitchOwnership(t *testing.T) {
	for _, custom := range []bool{false, true} {
		t.Run(fmt.Sprint(custom), func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"closeConnections": true, "openLogs": false, "ownedSettings": []string{"app.closeConnections", "app.openLogs"}})}, 0); err != nil {
				t.Fatal(err)
			}
			headers := map[string]string{"flclashm-settings": "openlogs,autoupdate"}
			if custom {
				headers["flclashm-custom"] = "update"
			}
			if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(headers)}, false, true); err != nil {
				t.Fatal(err)
			}
			var settings struct {
				Close  bool `json:"closeConnections"`
				Logs   bool `json:"openLogs"`
				Update bool `json:"autoCheckUpdate"`
			}
			if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
				t.Fatal(err)
			}
			if !settings.Close || settings.Logs || !settings.Update {
				t.Fatal(settings)
			}
		})
	}
}

// TestInactiveProfileCustomization waits for selection before changing app controls.
func TestInactiveProfileCustomization(t *testing.T) {
	for _, custom := range []bool{false, true} {
		t.Run(fmt.Sprint(custom), func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"closeConnections": true, "openLogs": true})}, 0); err != nil {
				t.Fatal(err)
			}
			headers := map[string]string{"flclashm-settings": "autoupdate", "flclashm-view": "app.glass:ultra"}
			if custom {
				headers["flclashm-custom"] = "update"
			}
			metadata := profiles.Object{"id": jsonValue("inactive"), "providerHeaders": jsonValue(headers)}
			if err := app.customizeForProfile(context.Background(), metadata, true, false); err != nil {
				t.Fatal(err)
			}
			read := func() {
				var settings struct {
					Close bool `json:"closeConnections"`
					Logs  bool `json:"openLogs"`
				}
				_ = json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings)
				if !settings.Close || !settings.Logs {
					t.Fatal("inactive subscription changed controls", settings)
				}
			}
			read()
			if err := app.customizeForProfile(context.Background(), metadata, false, true); err != nil {
				t.Fatal(err)
			}
			var settings struct {
				Close bool `json:"closeConnections"`
				Logs  bool `json:"openLogs"`
			}
			_ = json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings)
			if settings.Close || settings.Logs {
				t.Fatal("selection did not apply controls", settings)
			}
		})
	}
}
