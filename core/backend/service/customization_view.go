package service

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"core/backend/profiles"
)

// Modern appearance hints are persisted by Go even when no UI is attached.
// User-owned settings remain authoritative, as in the UI projection.
func (a *App) customizeView(ctx context.Context, metadata profiles.Object) error {
	var headers map[string]string
	_ = json.Unmarshal(metadata["providerHeaders"], &headers)
	catalog := a.profiles.Snapshot()
	var app profiles.Object
	_ = json.Unmarshal(catalog.Settings["appSetting"], &app)
	var owned []string
	_ = json.Unmarshal(app["ownedSettings"], &owned)
	owns := func(key string) bool {
		for _, item := range owned {
			if item == key {
				return true
			}
		}
		return false
	}
	style, theme, appPatch := profiles.Object{}, profiles.Object{}, profiles.Object{}
	set := func(target profiles.Object, key, setting string, value any) {
		if !owns(setting) {
			target[key] = jsonValue(value)
		}
	}
	// Without the legacy custom trigger, upstream settings and widget hints
	// apply directly. Explicit legacy triggers retain their original semantics.
	_, customM := headers["flclashm-custom"]
	_, customX := headers["flclashx-custom"]
	if !customM && !customX {
		_, settingsM := headers["flclashm-settings"]
		_, settingsX := headers["flclashx-settings"]
		var override bool
		_ = json.Unmarshal(app["overrideProviderSettings"], &override)
		if (settingsM || settingsX) && !override {
			enabled := map[string]bool{}
			for _, value := range strings.Split(profiles.ProviderHeader(headers, "settings"), ",") {
				enabled[strings.ToLower(strings.TrimSpace(value))] = true
			}
			for field, flag := range map[string]string{"minimizeOnExit": "minimize", "autoLaunch": "autorun", "silentLaunch": "shadowstart", "autoRun": "autostart", "autoCheckUpdate": "autoupdate", "openLogs": "openlogs", "closeConnections": "closeconnections"} {
				set(appPatch, field, "app."+field, enabled[flag])
			}
		}
		names := map[string]string{}
		for _, name := range []string{"currentOutbound", "announcement", "networkSpeed", "outboundMode", "vpnButton", "networkTakeover", "serviceStatus", "profiles", "proxyGroups", "connectionStats", "intranetIp", "memoryInfo"} {
			names[strings.ToLower(name)] = name
		}
		widgets := []string{}
		seen := map[string]bool{}
		for _, name := range strings.Split(profiles.ProviderHeader(headers, "widgets"), ",") {
			if canonical := names[strings.ToLower(strings.TrimSpace(name))]; canonical != "" && !seen[canonical] {
				seen[canonical] = true
				widgets = append(widgets, canonical)
			}
		}
		if len(widgets) > 0 {
			appPatch["dashboardWidgets"] = jsonValue(widgets)
		}
	}
	choices := map[string][]string{
		"proxies.type": {"list", "tab"}, "proxies.sort": {"none", "delay", "name"},
		"proxies.layout": {"loose", "standard", "tight"}, "proxies.icon": {"filled", "plain", "hidden"},
		"proxies.card": {"loose", "standard", "compact"}, "app.board": {"extended", "standard"},
		"app.navbar": {"floating", "docked"}, "app.tabs": {"slide", "fade"},
		"app.glass": {"none", "standard", "ultra"}, "app.style": {"vivid", "tinted", "soft", "monochrome"},
	}
	fields := map[string]string{"proxies.type": "type", "proxies.sort": "sortType", "proxies.layout": "layout", "proxies.icon": "iconStyle", "proxies.card": "cardType", "app.board": "style", "app.tabs": "tabAnimation", "app.glass": "liquidGlass", "app.style": "colorStyle"}
	for _, entry := range strings.Split(profiles.ProviderHeader(headers, "view"), ";") {
		key, value, ok := strings.Cut(entry, ":")
		if !ok {
			continue
		}
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.ToLower(strings.TrimSpace(value))
		if !strings.Contains(key, ".") {
			key = "proxies." + key
		}
		if key == "proxies.icon" {
			switch value {
			case "icon", "standard":
				value = "filled"
			case "none":
				value = "hidden"
			}
		}
		if key == "proxies.card" {
			switch value {
			case "expand":
				value = "loose"
			case "shrink":
				value = "standard"
			case "min", "oneline":
				value = "compact"
			}
		}
		if key == "app.color" {
			hex := strings.TrimPrefix(value, "#")
			if len(hex) != 6 && len(hex) != 8 {
				continue
			}
			if len(hex) == 6 {
				hex = "ff" + hex
			}
			color, err := strconv.ParseUint(hex, 16, 32)
			if err != nil || owns("view.app.color") {
				continue
			}
			theme["primaryColor"] = jsonValue(color)
			var current profiles.Object
			_ = json.Unmarshal(catalog.Settings["themeProps"], &current)
			var colors []uint64
			_ = json.Unmarshal(current["primaryColors"], &colors)
			found := false
			for _, item := range colors {
				found = found || item == color
			}
			if !found {
				colors = append(colors, color)
			}
			theme["primaryColors"] = jsonValue(colors)
			continue
		}
		if key == "app.black" {
			switch value {
			case "true", "yes", "1":
				set(theme, "pureBlack", "view.app.black", true)
			case "false", "no", "0":
				set(theme, "pureBlack", "view.app.black", false)
			}
			continue
		}
		valid := false
		for _, choice := range choices[key] {
			valid = valid || value == choice
		}
		if !valid {
			continue
		}
		switch {
		case strings.HasPrefix(key, "proxies."):
			set(style, fields[key], "view."+key, value)
		case key == "app.navbar":
			set(appPatch, "floatingNavigationBar", "view.app.navbar", value == "floating")
		case key == "app.tabs":
			set(appPatch, fields[key], "view.app.tabs", value)
		case key == "app.board":
			if value == "extended" {
				value = "enhanced"
			} else {
				value = "original"
			}
			set(theme, "style", "view.app.board", value)
		case key == "app.style":
			set(theme, fields[key], "view.app.color", value)
		default:
			set(theme, fields[key], "view."+key, value)
		}
	}
	patch := profiles.Object{}
	if len(style) > 0 {
		patch["proxiesStyle"] = jsonValue(style)
	}
	if len(theme) > 0 {
		patch["themeProps"] = jsonValue(theme)
	}
	if len(appPatch) > 0 {
		patch["appSetting"] = jsonValue(appPatch)
	}
	if len(patch) == 0 {
		return nil
	}
	return a.patchSettings(ctx, patch, 0)
}
