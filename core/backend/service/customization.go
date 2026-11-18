package service

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"core/backend/profiles"
)

// Provider customization is a data policy. It runs headlessly and persists its
// result; Flutter only renders the projected settings and display-only headers.
// A header holds a setting only while the selected profile sends it: the user's
// own value waits in appSetting.headerBackup meanwhile.
func (a *App) customize(ctx context.Context, metadata profiles.Object, isNew bool) error {
	return a.customizeForProfile(ctx, metadata, isNew, false)
}

// customizeForProfile distinguishes explicit selection from an inactive import.
func (a *App) customizeForProfile(ctx context.Context, metadata profiles.Object, isNew, selecting bool) error {
	var id string
	_ = json.Unmarshal(metadata["id"], &id)
	active := selecting || a.isCurrent(id)
	if !active {
		return nil
	}
	return a.customizeSettings(ctx, metadata, isNew, selecting)
}

// customizeForSelection reapplies the current profile after a switch, a delete
// or an ownership change, so values a previous profile's headers held are put
// back before the next profile speaks.
func (a *App) customizeForSelection(ctx context.Context) error {
	var id string
	_ = json.Unmarshal(a.profiles.Snapshot().Settings["currentProfileId"], &id)
	if id == "" {
		return a.customizeSettings(ctx, profiles.Object{}, false, false)
	}
	record, err := a.profiles.Get(id)
	if err != nil {
		return nil
	}
	return a.customizeSettings(ctx, record.Metadata, false, false)
}

func (a *App) customizeSettings(ctx context.Context, metadata profiles.Object, isNew, selecting bool) error {
	var headers map[string]string
	_ = json.Unmarshal(metadata["providerHeaders"], &headers)
	catalog := a.profiles.Snapshot()
	var app profiles.Object
	_ = json.Unmarshal(catalog.Settings["appSetting"], &app)
	var override bool
	_ = json.Unmarshal(app["overrideProviderSettings"], &override)

	writer := newSettingsWriter(catalog, app)
	header := func(suffix string) string {
		return strings.TrimSpace(profiles.ProviderHeader(headers, suffix))
	}
	_, hasSettingsM := headers["flclashm-settings"]
	_, hasSettingsX := headers["flclashx-settings"]
	hasSettings := (hasSettingsM || hasSettingsX) && header("settings") != ""
	_, customM := headers["flclashm-custom"]
	_, customX := headers["flclashx-custom"]
	hasCustom := customM || customX
	trigger := strings.ToLower(header("custom"))
	controlsOnly := trigger == "add" && !isNew && selecting
	legacy := trigger == "update" || (trigger == "add" && isNew) || controlsOnly

	// Which app switches the panel turns on; the rest it turns off. The
	// legacy trigger replays only the controls it owns on a later selection.
	if hasSettings && !override && (legacy || !hasCustom) {
		enabled := map[string]bool{}
		for _, value := range strings.Split(header("settings"), ",") {
			enabled[strings.ToLower(strings.TrimSpace(value))] = true
		}
		for flag, field := range appSwitchFields {
			control := flag == "openlogs" || flag == "closeconnections"
			if controlsOnly && !control {
				continue
			}
			writer.set("app."+field, field, enabled[flag])
		}
	}

	if !controlsOnly {
		// Cards the user arranged stay put until the panel denies editing them
		// or the user hands the settings back to the subscription.
		denied := profiles.ProviderSpecial(headers, "denywidgets")
		if !denied {
			writer.releaseForcedWidgets()
		}
		if widgets := providerWidgets(header("widgets")); len(widgets) > 0 && (legacy || !hasCustom) {
			writer.setWidgets(widgets, denied)
		}
		if legacy {
			writer.applyLegacyHex(header("hex"))
		}
	}

	writer.applyView(headers)
	writer.applySpecials(headers)
	return writer.commit(ctx, a)
}

func (a *App) deviceHeadersEnabled(requested bool) bool {
	if !requested {
		return false
	}
	var enabled *bool
	_ = json.Unmarshal(a.profiles.Snapshot().Settings["sendDeviceHeaders"], &enabled)
	return enabled == nil || *enabled
}

func (a *App) deviceHeadersRequested(requested *bool) bool {
	enabled := requested == nil || *requested
	return a.deviceHeadersEnabled(enabled)
}

// defaultProviderPrimaryColors returns a fresh palette for each customization.
func defaultProviderPrimaryColors() []uint64 {
	return []uint64{0xFF795548, 0xFF03A9F4, 0xFFFFFF00, 0xFFBBC9CC, 0xFFABD397, 0xFFD8C0C3, 0xFF665390}
}

// providerWidgets accepts modern names and legacy aliases in both header paths.
func providerWidgets(raw string) []string {
	names := map[string]string{}
	for _, name := range []string{"networkSpeed", "outboundModeV2", "outboundMode", "trafficUsage", "announce", "metainfo", "networkDetection", "tunButton", "vpnButton", "systemProxyButton", "intranetIp", "memoryInfo", "changeServerButton", "serviceInfo", "zashboardButton", "currentOutbound", "announcement", "networkTakeover", "serviceStatus", "profiles", "proxyGroups", "connectionStats"} {
		names[strings.ToLower(name)] = name
	}
	widgets := []string{}
	seen := map[string]bool{}
	for _, name := range strings.Split(raw, ",") {
		if canonical := names[strings.ToLower(strings.TrimSpace(name))]; canonical != "" && !seen[canonical] {
			seen[canonical] = true
			widgets = append(widgets, canonical)
		}
	}
	return widgets
}

// appSwitchFields maps `flclashx-settings` flags to the app setting each one
// drives.
var appSwitchFields = map[string]string{
	"minimize":         "minimizeOnExit",
	"autorun":          "autoLaunch",
	"shadowstart":      "silentLaunch",
	"autostart":        "autoRun",
	"autoupdate":       "autoCheckUpdate",
	"openlogs":         "openLogs",
	"closeconnections": "closeConnections",
}

// legacyHexFields are the theme fields the legacy hex header sets.
func (w *settingsWriter) applyLegacyHex(raw string) {
	parts := strings.Split(raw, ":")
	hexValue := strings.ReplaceAll(strings.TrimSpace(parts[0]), "#", "")
	if len(hexValue) != 6 && len(hexValue) != 8 {
		return
	}
	if len(hexValue) == 6 {
		hexValue = "FF" + hexValue
	}
	color, err := strconv.ParseUint(hexValue, 16, 32)
	if err != nil {
		return
	}
	w.set("view.app.color", "primaryColor", uint64(color))
	w.setPaletteColor(uint64(color))
	pureBlack := false
	for _, part := range parts[1:] {
		pureBlack = pureBlack || strings.EqualFold(strings.TrimSpace(part), "pureblack")
	}
	// The legacy trigger always states blackness; the modern view key does not.
	w.set("view.app.black", "pureBlack", pureBlack)
	if len(parts) > 1 {
		variant := strings.TrimSpace(parts[1])
		for _, known := range []string{"tonalSpot", "fidelity", "monochrome", "neutral", "vibrant", "expressive", "content", "rainbow", "fruitSalad"} {
			if strings.EqualFold(variant, known) {
				w.set("view.app.color", "schemeVariant", known)
				break
			}
		}
	}
}
