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
func (a *App) customize(ctx context.Context, metadata profiles.Object, isNew bool) error {
	var headers map[string]string
	_ = json.Unmarshal(metadata["providerHeaders"], &headers)
	header := func(suffix string) string { return strings.TrimSpace(profiles.ProviderHeader(headers, suffix)) }
	trigger := strings.ToLower(header("custom"))
	if trigger != "update" && (trigger != "add" || !isNew) {
		return nil
	}
	catalog := a.profiles.Snapshot()
	patch := profiles.Object{}
	appPatch := profiles.Object{}
	var appSettings profiles.Object
	_ = json.Unmarshal(catalog.Settings["appSetting"], &appSettings)
	var override bool
	_ = json.Unmarshal(appSettings["overrideProviderSettings"], &override)
	_, hasM := headers["flclashm-settings"]
	_, hasX := headers["flclashx-settings"]
	if (hasM || hasX) && !override {
		enabled := map[string]bool{}
		for _, value := range strings.Split(header("settings"), ",") {
			enabled[strings.ToLower(strings.TrimSpace(value))] = true
		}
		for field, token := range map[string]string{"minimizeOnExit": "minimize", "autoLaunch": "autorun", "silentLaunch": "shadowstart", "autoRun": "autostart", "autoCheckUpdate": "autoupdate"} {
			appPatch[field] = jsonValue(enabled[token])
		}
	}
	widgets := []string{}
	names := map[string]string{}
	for _, name := range []string{"networkSpeed", "outboundModeV2", "outboundMode", "trafficUsage", "announce", "metainfo", "networkDetection", "tunButton", "vpnButton", "systemProxyButton", "intranetIp", "memoryInfo", "changeServerButton", "serviceInfo", "zashboardButton"} {
		names[strings.ToLower(name)] = name
	}
	for _, name := range strings.Split(header("widgets"), ",") {
		if canonical := names[strings.ToLower(strings.TrimSpace(name))]; canonical != "" {
			widgets = append(widgets, canonical)
		}
	}
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
			colors := []uint64{0xFF795548, 0xFF03A9F4, 0xFFFFFF00, 0xFFBBC9CC, 0xFFABD397, 0xFFD8C0C3, 0xFF665390}
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
	style := profiles.Object{}
	allowed := map[string][]string{"type": {"list", "tab"}, "sort": {"none", "delay", "name"}, "layout": {"loose", "standard", "tight"}, "icon": {"icon", "none", "standard"}, "card": {"expand", "shrink", "min", "oneline"}}
	fields := map[string]string{"type": "type", "sort": "sortType", "layout": "layout", "icon": "iconStyle", "card": "cardType"}
	for _, setting := range strings.Split(header("view"), ";") {
		parts := strings.Split(setting, ":")
		if len(parts) != 2 {
			continue
		}
		key, value := strings.ToLower(strings.TrimSpace(parts[0])), strings.ToLower(strings.TrimSpace(parts[1]))
		for _, known := range allowed[key] {
			if value == known {
				if key == "icon" && value == "standard" {
					value = "icon"
				}
				style[fields[key]] = jsonValue(value)
				break
			}
		}
	}
	if len(style) > 0 {
		patch["proxiesStyle"] = jsonValue(style)
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
