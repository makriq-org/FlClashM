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
			if theme["liquidGlass"] != "ultra" || theme["primaryColor"] != float64(0xff123456) || theme["pureBlack"] != true || theme["colorStyle"] != "soft" {
				t.Fatal(theme)
			}
			if _, ok := theme["style"]; ok {
				t.Fatal("app.board still changes the dashboard style", theme)
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
			if theme["liquidGlass"] != "ultra" || theme["pureBlack"] != true || theme["primaryColor"] != nil {
				t.Fatal("invalid header must release the previous color without overriding owned settings", theme)
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

// TestDashboardCardsStayAsTheUserArranged covers the cards a subscription must
// not put back: an arrangement survives an update unless the panel denies
// editing, and giving the setting back lets the panel's list return.
func TestDashboardCardsStayAsTheUserArranged(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	apply := func(headers map[string]string) []string {
		t.Helper()
		if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(headers)}, false, true); err != nil {
			t.Fatal(err)
		}
		var settings struct {
			Widgets []string `json:"dashboardWidgets"`
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
			t.Fatal(err)
		}
		return settings.Widgets
	}
	panels := []string{"announcement", "outboundMode"}
	if got := apply(map[string]string{"flclashm-widgets": "announcement,outboundMode"}); !reflect.DeepEqual(got, panels) {
		t.Fatalf("panel cards = %v, want %v", got, panels)
	}
	// The user edits the dashboard, which marks the cards as their own.
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{
		"dashboardWidgets": []string{"outboundMode"},
		"ownedSettings":    []string{"app.dashboardWidgets"},
	})}, 0); err != nil {
		t.Fatal(err)
	}
	if got := apply(map[string]string{"flclashm-widgets": "announcement,outboundMode"}); !reflect.DeepEqual(got, []string{"outboundMode"}) {
		t.Fatalf("an update replaced the user's cards: %v", got)
	}
	if got := apply(map[string]string{"flclashm-widgets": "announcement,outboundMode", "flclashm-special": "denywidgets"}); !reflect.DeepEqual(got, panels) {
		t.Fatalf("denywidgets did not restore the panel's cards: %v", got)
	}
	// Handing the setting back is what lets the panel speak for the cards
	// again without denywidgets.
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"ownedSettings": []string{}})}, 0); err != nil {
		t.Fatal(err)
	}
	if got := apply(map[string]string{"flclashm-widgets": "announcement,outboundMode"}); !reflect.DeepEqual(got, panels) {
		t.Fatalf("released cards did not follow the panel: %v", got)
	}
}

// TestViewHeaderTakesThemeAndHiddenTimeouts covers the two view keys that shape
// the app theme and the proxies page, in both header prefixes.
func TestViewHeaderTakesThemeAndHiddenTimeouts(t *testing.T) {
	for _, prefix := range []string{"flclashm-", "flclashx-"} {
		t.Run(prefix, func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(map[string]string{
				prefix + "view": "app.theme:dark;proxies.hidetimeout:true",
			})}, false, true); err != nil {
				t.Fatal(err)
			}
			var theme struct {
				Mode string `json:"themeMode"`
			}
			if err := json.Unmarshal(app.Snapshot().Catalog.Settings["themeProps"], &theme); err != nil {
				t.Fatal(err)
			}
			var style struct {
				HideTimeout bool `json:"hideTimeoutProxies"`
			}
			if err := json.Unmarshal(app.Snapshot().Catalog.Settings["proxiesStyle"], &style); err != nil {
				t.Fatal(err)
			}
			if theme.Mode != "dark" || !style.HideTimeout {
				t.Fatalf("theme %+v, style %+v", theme, style)
			}
			// An invalid value leaves the saved setting alone.
			if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(map[string]string{
				prefix + "view": "app.theme:sunset;proxies.hidetimeout:maybe",
			})}, false, true); err != nil {
				t.Fatal(err)
			}
			_ = json.Unmarshal(app.Snapshot().Catalog.Settings["themeProps"], &theme)
			_ = json.Unmarshal(app.Snapshot().Catalog.Settings["proxiesStyle"], &style)
			if theme.Mode != "dark" || !style.HideTimeout {
				t.Fatalf("an invalid value changed the settings: %+v %+v", theme, style)
			}
		})
	}
}

// TestHideIpFlagComesAndGoesWithThePanel keeps the flag reversible: it is on
// while the panel sends it and back off once it stops, unless the user took it.
func TestHideIpFlagComesAndGoesWithThePanel(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	read := func() (bool, []string) {
		t.Helper()
		var settings struct {
			HideIp   bool     `json:"hideIp"`
			PanelSet []string `json:"panelSetSettings"`
			Owned    []string `json:"ownedSettings"`
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
			t.Fatal(err)
		}
		return settings.HideIp, settings.PanelSet
	}
	apply := func(special string) {
		t.Helper()
		if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(map[string]string{"flclashm-special": special})}, false, true); err != nil {
			t.Fatal(err)
		}
	}
	apply("hideip")
	if on, set := read(); !on || !reflect.DeepEqual(set, []string{"app.hideIp"}) {
		t.Fatalf("hideip = %v, panel set %v", on, set)
	}
	apply("")
	if on, set := read(); on || len(set) != 0 {
		t.Fatalf("hideip stayed on without the flag: %v, panel set %v", on, set)
	}
	// A setting the user owns is never turned on or off by the panel.
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"ownedSettings": []string{"app.hideIp"}})}, 0); err != nil {
		t.Fatal(err)
	}
	apply("hideip")
	if on, set := read(); on || len(set) != 0 {
		t.Fatalf("hideip overrode the user's setting: %v, panel set %v", on, set)
	}
}

// TestHideIpMarkerSurvivesUserOwnership keeps the panel's marker while the user
// owns the setting: dropping it there would leave the value the panel set with
// nothing to reset once the setting is handed back.
func TestHideIpMarkerSurvivesUserOwnership(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	read := func() (bool, []string) {
		t.Helper()
		var settings struct {
			HideIp   bool     `json:"hideIp"`
			PanelSet []string `json:"panelSetSettings"`
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
			t.Fatal(err)
		}
		return settings.HideIp, settings.PanelSet
	}
	apply := func(special string) {
		t.Helper()
		if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(map[string]string{"flclashm-special": special})}, false, true); err != nil {
			t.Fatal(err)
		}
	}
	patch := func(fields map[string]any) {
		t.Helper()
		if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(fields)}, 0); err != nil {
			t.Fatal(err)
		}
	}
	apply("hideip")
	if on, set := read(); !on || !reflect.DeepEqual(set, []string{"app.hideIp"}) {
		t.Fatalf("hideip = %v, panel set %v", on, set)
	}
	// The user takes the setting and turns it off; the panel still sends the flag.
	patch(map[string]any{"hideIp": false, "ownedSettings": []string{"app.hideIp"}})
	apply("hideip")
	if on, set := read(); on || !reflect.DeepEqual(set, []string{"app.hideIp"}) {
		t.Fatalf("the panel overrode the user: hideip = %v, panel set %v", on, set)
	}
	// The panel stops sending it while the user still owns the setting.
	apply("")
	if on, set := read(); on || !reflect.DeepEqual(set, []string{"app.hideIp"}) {
		t.Fatalf("the marker was dropped under the user: hideip = %v, panel set %v", on, set)
	}
	// Handing it back now clears the marker and the value the panel once set.
	patch(map[string]any{"ownedSettings": []string{}})
	apply("")
	if on, set := read(); on || len(set) != 0 {
		t.Fatalf("released setting kept the panel's value: hideip = %v, panel set %v", on, set)
	}
}

// TestHeaderSettingsLastWhileTheirProfileIsSelected covers the temporary
// override: what a panel's view, settings and special headers set goes back to
// the user's own values once another profile is selected, and a late refresh
// of a profile that is not in use changes nothing.
func TestHeaderSettingsLastWhileTheirProfileIsSelected(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	if err := app.patchSettings(context.Background(), profiles.Object{
		"appSetting":   jsonValue(map[string]any{"openLogs": true, "dashboardWidgets": []string{"currentOutbound", "profiles"}}),
		"themeProps":   jsonValue(map[string]any{"themeMode": "light", "liquidGlass": "none"}),
		"proxiesStyle": jsonValue(map[string]any{"hideTimeoutProxies": false, "cardType": "standard"}),
	}, 0); err != nil {
		t.Fatal(err)
	}
	read := func() (string, string, bool, string, bool, bool, bool, bool, []string) {
		t.Helper()
		var theme struct {
			Mode  string `json:"themeMode"`
			Glass string `json:"liquidGlass"`
		}
		var style struct {
			Hide     bool   `json:"hideTimeoutProxies"`
			Card     string `json:"cardType"`
			Floating bool   `json:"-"`
		}
		var settings struct {
			OpenLogs        bool     `json:"openLogs"`
			AutoCheckUpdate bool     `json:"autoCheckUpdate"`
			HideIp          bool     `json:"hideIp"`
			Vibration       bool     `json:"vibration"`
			Widgets         []string `json:"dashboardWidgets"`
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["themeProps"], &theme); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["proxiesStyle"], &style); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
			t.Fatal(err)
		}
		return theme.Mode, theme.Glass, style.Hide, style.Card, settings.OpenLogs, settings.AutoCheckUpdate, settings.HideIp, settings.Vibration, settings.Widgets
	}
	apply := func(id string, headers map[string]string, selecting bool) {
		t.Helper()
		metadata := profiles.Object{"id": jsonValue(id), "providerHeaders": jsonValue(headers)}
		if err := app.customizeForProfile(context.Background(), metadata, false, selecting); err != nil {
			t.Fatal(err)
		}
	}
	if err := app.patchSettings(context.Background(), profiles.Object{"currentProfileId": jsonValue("a")}, 0); err != nil {
		t.Fatal(err)
	}
	apply("a", map[string]string{
		"flclashx-view":     "app.theme:dark;app.glass:ultra;proxies.hidetimeout:true;proxies.card:oneline",
		"flclashx-settings": "autoupdate",
		"flclashx-widgets":  "profiles,proxyGroups",
		"flclashx-special":  "novibrate,hideip",
	}, true)
	if mode, glass, hide, card, openLogs, autoUpdate, hideIp, vibration, widgets := read(); mode != "dark" || glass != "ultra" || !hide || card != "oneline" || openLogs || !autoUpdate || !hideIp || vibration || !reflect.DeepEqual(widgets, []string{"profiles", "proxyGroups"}) {
		t.Fatalf("the panel's headers did not apply: %q %q %v %q openLogs=%v autoUpdate=%v hideIp=%v vibration=%v %v", mode, glass, hide, card, openLogs, autoUpdate, hideIp, vibration, widgets)
	}
	// A refresh of a profile that is not selected must not touch them.
	apply("b", map[string]string{"flclashx-view": "app.theme:light;proxies.card:compact"}, false)
	if mode, _, _, card, _, _, _, _, _ := read(); mode != "dark" || card != "oneline" {
		t.Fatalf("a late refresh of another profile overwrote the selected one: %q %q", mode, card)
	}
	// Selecting a profile without such headers gives the user's values back.
	apply("b", nil, true)
	if mode, glass, hide, card, openLogs, autoUpdate, hideIp, vibration, widgets := read(); mode != "light" || glass != "none" || hide || card != "standard" || !openLogs || autoUpdate || hideIp || !vibration || !reflect.DeepEqual(widgets, []string{"currentOutbound", "profiles"}) {
		t.Fatalf("the user's own values did not return: %q %q %v %q openLogs=%v autoUpdate=%v hideIp=%v vibration=%v %v", mode, glass, hide, card, openLogs, autoUpdate, hideIp, vibration, widgets)
	}
}

// TestArrangedCardsSurviveThePanelOnlyWhileEditingIsAllowed covers the order a
// user picked: a panel's widget list replaces it only under denywidgets, and
// the user's own list comes back afterwards.
func TestArrangedCardsSurviveThePanelOnlyWhileEditingIsAllowed(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{
		"dashboardWidgets": []string{"proxyGroups", "currentOutbound"},
		"ownedSettings":    []string{"app.dashboardWidgets"},
	})}, 0); err != nil {
		t.Fatal(err)
	}
	apply := func(special string) []string {
		t.Helper()
		headers := map[string]string{"flclashx-widgets": "profiles,announcement"}
		if special != "" {
			headers["flclashx-special"] = special
		}
		if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(headers)}, false, true); err != nil {
			t.Fatal(err)
		}
		var settings struct {
			Widgets []string `json:"dashboardWidgets"`
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
			t.Fatal(err)
		}
		return settings.Widgets
	}
	if got := apply(""); !reflect.DeepEqual(got, []string{"proxyGroups", "currentOutbound"}) {
		t.Fatalf("an update replaced the user's order: %v", got)
	}
	if got := apply("denywidgets"); !reflect.DeepEqual(got, []string{"profiles", "announcement"}) {
		t.Fatalf("denywidgets did not take the cards: %v", got)
	}
	if got := apply(""); !reflect.DeepEqual(got, []string{"proxyGroups", "currentOutbound"}) {
		t.Fatalf("the user's order did not come back: %v", got)
	}
}

// TestNoVibrationFlagComesAndGoesWithThePanel keeps `novibrate` reversible.
func TestNoVibrationFlagComesAndGoesWithThePanel(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	read := func() bool {
		t.Helper()
		var settings struct {
			Vibration bool `json:"vibration"`
		}
		if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
			t.Fatal(err)
		}
		return settings.Vibration
	}
	apply := func(special string) {
		t.Helper()
		if err := app.customizeForProfile(context.Background(), profiles.Object{"providerHeaders": jsonValue(map[string]string{"flclashx-special": special})}, false, true); err != nil {
			t.Fatal(err)
		}
	}
	apply("novibrate")
	if read() {
		t.Fatal("novibrate did not turn vibration off")
	}
	apply("")
	if !read() {
		t.Fatal("vibration stayed off without the flag")
	}
}
