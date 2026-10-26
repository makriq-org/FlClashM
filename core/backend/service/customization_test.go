package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
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
	if err := app.customizeForProfile(context.Background(), metadata, false, true); err != nil {
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
	if style["type"] != "tab" || style["iconStyle"] != "filled" || style["cardType"] != "compact" {
		t.Fatal(style)
	}
	if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"overrideProviderSettings": false})}, 0); err != nil {
		t.Fatal(err)
	}
	if err := app.customizeForProfile(context.Background(), metadata, false, true); err != nil {
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

func TestCustomizationTriggerAndLiteralDisplayCompatibility(t *testing.T) {
	for _, test := range []struct {
		trigger             string
		newProfile, applies bool
	}{{"add", true, true}, {"add", false, false}, {"update", false, true}, {"", true, false}} {
		t.Run(test.trigger+fmt.Sprint(test.newProfile), func(t *testing.T) {
			app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
			if err := app.patchSettings(context.Background(), profiles.Object{"appSetting": jsonValue(map[string]any{"autoLaunch": false})}, 0); err != nil {
				t.Fatal(err)
			}
			metadata := profiles.Object{"providerHeaders": jsonValue(map[string]string{"flclashm-custom": test.trigger, "flclashm-settings": "autorun"})}
			if err := app.customizeForProfile(context.Background(), metadata, test.newProfile, true); err != nil {
				t.Fatal(err)
			}
			var settings struct {
				AutoLaunch bool `json:"autoLaunch"`
			}
			_ = json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings)
			if settings.AutoLaunch != test.applies {
				t.Fatal("customization trigger changed", settings)
			}
		})
	}
	for _, value := range []string{"Сервис 🛰", "literal service", "test"} {
		for _, header := range []string{value, base64.StdEncoding.EncodeToString([]byte(value)), base64.RawURLEncoding.EncodeToString([]byte(value))} {
			if got := decodeProviderHeader(header); got != value {
				t.Fatalf("display header %q became %q", header, got)
			}
		}
	}
}

// TestDeferredAddSettings keeps import-only fields intact when delayed controls
// are applied after reopening the backend and explicitly selecting the profile.
func TestDeferredAddSettings(t *testing.T) {
	for _, prefix := range []string{"flclashm-", "flclashx-"} {
		for _, override := range []bool{false, true} {
			for _, owned := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/override=%v/owned=%v", prefix, override, owned), func(t *testing.T) {
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						w.Header().Set(prefix+"custom", "add")
						w.Header().Set(prefix+"settings", "openlogs,closeconnections,autoupdate")
						w.Header().Set(prefix+"hex", "112233")
						w.Header().Set(prefix+"widgets", "profiles")
						_, _ = w.Write([]byte("rules: ['MATCH,DIRECT']"))
					}))
					defer server.Close()
					opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
					opts.HTTPClient = server.Client()
					app := openTestApp(t, opts)
					ownedSettings := []string{}
					if owned {
						ownedSettings = append(ownedSettings, "app.closeConnections")
					}
					request(t, app, "initial", "settings.patch", map[string]any{"patch": map[string]any{"appSetting": map[string]any{"openLogs": false, "closeConnections": false, "overrideProviderSettings": override, "ownedSettings": ownedSettings}}})
					waitDomain(t, app, "initial")
					request(t, app, "import", "profile.import.url", map[string]any{"metadata": map[string]any{"id": "deferred", "url": server.URL}, "select": false})
					waitDomain(t, app, "import")
					read := func() (settings struct {
						OpenLogs, CloseConnections, AutoCheckUpdate bool
						DashboardWidgets                            []string
					}) {
						if err := json.Unmarshal(app.Snapshot().Catalog.Settings["appSetting"], &settings); err != nil {
							t.Fatal(err)
						}
						return
					}
					if settings := read(); settings.OpenLogs || settings.CloseConnections {
						t.Fatal("inactive import changed controls", settings)
					}
					// Changes after import must not be replaced by add-only hints on selection.
					request(t, app, "customize", "settings.patch", map[string]any{"patch": map[string]any{
						"appSetting": map[string]any{"autoCheckUpdate": false, "dashboardWidgets": []string{"serviceStatus"}},
						"themeProps": map[string]any{"primaryColor": uint64(0xffabcdef)},
					}})
					waitDomain(t, app, "customize")
					if err := app.Close(); err != nil {
						t.Fatal(err)
					}
					app = openTestApp(t, opts)
					request(t, app, "select", "profile.select", map[string]any{"profileId": "deferred"})
					waitDomain(t, app, "select")
					settings := read()
					if settings.OpenLogs != !override || settings.CloseConnections != (!override && !owned) {
						t.Fatal("selection did not respect deferred controls and ownership", settings)
					}
					var theme struct{ PrimaryColor uint64 }
					if err := json.Unmarshal(app.Snapshot().Catalog.Settings["themeProps"], &theme); err != nil {
						t.Fatal(err)
					}
					if settings.AutoCheckUpdate || len(settings.DashboardWidgets) != 1 || settings.DashboardWidgets[0] != "serviceStatus" || theme.PrimaryColor != 0xffabcdef {
						t.Fatal("selection replayed add-only hints", settings, theme)
					}
					request(t, app, "controls", "settings.patch", map[string]any{"patch": map[string]any{"appSetting": map[string]any{"openLogs": false, "closeConnections": false}}})
					waitDomain(t, app, "controls")
					request(t, app, "refresh", "subscription.refresh", map[string]any{"profileId": "deferred"})
					waitDomain(t, app, "refresh")
					if settings := read(); settings.OpenLogs || settings.CloseConnections {
						t.Fatal("refresh replayed add-only controls", settings)
					}
				})
			}
		}
	}
}
