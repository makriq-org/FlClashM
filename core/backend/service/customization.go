package service

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"strings"

	"core/backend/profiles"
)

// Provider customization is a data policy. It runs headlessly and persists its
// result; Flutter only renders the projected settings and display-only headers.
func (a *App) customize(ctx context.Context, metadata profiles.Object, isNew bool) error {
	return a.customizeForProfile(ctx, metadata, isNew, false)
}

// customizeForProfile distinguishes explicit selection from an inactive import.
func (a *App) customizeForProfile(ctx context.Context, metadata profiles.Object, isNew, selecting bool) error {
	var id string
	_ = json.Unmarshal(metadata["id"], &id)
	active := selecting || a.isCurrent(id)
	if err := a.customizeLegacy(ctx, metadata, isNew, active, selecting); err != nil {
		return err
	}
	if !active {
		return nil
	}
	return a.customizeView(ctx, metadata)
}

func (a *App) customizeLegacy(ctx context.Context, metadata profiles.Object, isNew, active, selecting bool) error {
	var headers map[string]string
	_ = json.Unmarshal(metadata["providerHeaders"], &headers)
	header := func(suffix string) string { return strings.TrimSpace(profiles.ProviderHeader(headers, suffix)) }
	trigger := strings.ToLower(header("custom"))
	// An inactive add import defers these controls until explicit selection.
	// Replaying them must not replay import-only appearance or startup settings.
	controlsOnly := trigger == "add" && !isNew && selecting
	if trigger != "update" && (trigger != "add" || !isNew) && !controlsOnly {
		return nil
	}
	catalog := a.profiles.Snapshot()
	patch := profiles.Object{}
	appPatch := profiles.Object{}
	var appSettings profiles.Object
	_ = json.Unmarshal(catalog.Settings["appSetting"], &appSettings)
	var owned []string
	_ = json.Unmarshal(appSettings["ownedSettings"], &owned)
	var override bool
	_ = json.Unmarshal(appSettings["overrideProviderSettings"], &override)
	_, hasM := headers["flclashm-settings"]
	_, hasX := headers["flclashx-settings"]
	if (hasM || hasX) && !override {
		enabled := map[string]bool{}
		for _, value := range strings.Split(header("settings"), ",") {
			enabled[strings.ToLower(strings.TrimSpace(value))] = true
		}
		for field, token := range map[string]string{"minimizeOnExit": "minimize", "autoLaunch": "autorun", "silentLaunch": "shadowstart", "autoRun": "autostart", "autoCheckUpdate": "autoupdate", "openLogs": "openlogs", "closeConnections": "closeconnections"} {
			control := field == "openLogs" || field == "closeConnections"
			if (!active && control) || (controlsOnly && !control) {
				continue
			}
			if !slices.Contains(owned, "app."+field) {
				appPatch[field] = jsonValue(enabled[token])
			}
		}
	}
	if controlsOnly {
		if len(appPatch) == 0 {
			return nil
		}
		return a.patchSettings(ctx, profiles.Object{"appSetting": jsonValue(appPatch)}, 0)
	}
	widgets := providerWidgets(header("widgets"))
	if len(widgets) > 0 {
		appPatch["dashboardWidgets"] = jsonValue(widgets)
	}
	if len(appPatch) > 0 {
		patch["appSetting"] = jsonValue(appPatch)
	}
	parts := strings.Split(header("hex"), ":")
	hexValue := strings.ReplaceAll(strings.TrimSpace(parts[0]), "#", "")
	if len(hexValue) == 6 || len(hexValue) == 8 {
		if len(hexValue) == 6 {
			hexValue = "FF" + hexValue
		}
		if color, err := strconv.ParseUint(hexValue, 16, 32); err == nil {
			var current profiles.Object
			_ = json.Unmarshal(catalog.Settings["themeProps"], &current)
			colors := defaultProviderPrimaryColors()
			if value, ok := current["primaryColors"]; ok {
				_ = json.Unmarshal(value, &colors)
			}
			contains := false
			for _, value := range colors {
				contains = contains || value == color
			}
			if !contains {
				colors = append(colors, color)
			}
			theme := profiles.Object{"primaryColor": jsonValue(color), "primaryColors": jsonValue(colors)}
			pureBlack := false
			for _, part := range parts[1:] {
				pureBlack = pureBlack || strings.EqualFold(strings.TrimSpace(part), "pureblack")
			}
			theme["pureBlack"] = jsonValue(pureBlack)
			if len(parts) > 1 {
				variant := strings.TrimSpace(parts[1])
				for _, known := range []string{"tonalSpot", "fidelity", "monochrome", "neutral", "vibrant", "expressive", "content", "rainbow", "fruitSalad"} {
					if strings.EqualFold(variant, known) {
						theme["schemeVariant"] = jsonValue(known)
						break
					}
				}
			}
			patch["themeProps"] = jsonValue(theme)
		}
	}
	if len(patch) == 0 {
		return nil
	}
	return a.patchSettings(ctx, patch, 0)
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
