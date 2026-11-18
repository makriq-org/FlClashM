package service

import (
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strconv"
	"strings"

	"core/backend/profiles"
)

// providerWidgetsSetting marks the dashboard cards as the user's own, so a
// subscription update leaves an arrangement alone unless it denies editing.
const providerWidgetsSetting = "app.dashboardWidgets"

// forcedWidgetsBackup marks the cards as taken by `denywidgets`, so the user's
// own arrangement comes back once the panel stops denying editing.
const forcedWidgetsBackup = "app.dashboardWidgets.forced"

// viewField is where a header key lands in the settings catalog.
type viewField struct {
	setting  string
	field    string
	fallback any
}

// viewKeyFields maps a logical header setting to the catalog fields it holds.
// `app.board` is absent on purpose: the extended board is gone and the key is
// ignored instead of shaping the standard page.
var viewKeyFields = map[string][]viewField{
	"view.proxies.type":        {{"proxiesStyle", "type", "list"}},
	"view.proxies.sort":        {{"proxiesStyle", "sortType", "none"}},
	"view.proxies.layout":      {{"proxiesStyle", "layout", "standard"}},
	"view.proxies.icon":        {{"proxiesStyle", "iconStyle", "filled"}},
	"view.proxies.card":        {{"proxiesStyle", "cardType", "standard"}},
	"view.proxies.hidetimeout": {{"proxiesStyle", "hideTimeoutProxies", false}},
	"view.app.theme":           {{"themeProps", "themeMode", "system"}},
	"view.app.navbar":          {{"appSetting", "floatingNavigationBar", true}},
	"view.app.tabs":            {{"appSetting", "tabAnimation", "fade"}},
	"view.app.glass":           {{"themeProps", "liquidGlass", "none"}},
	"view.app.black":           {{"themeProps", "pureBlack", false}},
	"view.app.color": {
		{"themeProps", "primaryColor", nil},
		{"themeProps", "primaryColors", nil},
		{"themeProps", "colorStyle", "vivid"},
		{"themeProps", "schemeVariant", nil},
	},
	"app.minimizeOnExit":   {{"appSetting", "minimizeOnExit", false}},
	"app.autoLaunch":       {{"appSetting", "autoLaunch", false}},
	"app.silentLaunch":     {{"appSetting", "silentLaunch", false}},
	"app.autoRun":          {{"appSetting", "autoRun", false}},
	"app.autoCheckUpdate":  {{"appSetting", "autoCheckUpdate", false}},
	"app.openLogs":         {{"appSetting", "openLogs", false}},
	"app.closeConnections": {{"appSetting", "closeConnections", true}},
	"app.hideIp":           {{"appSetting", "hideIp", false}},
	"app.vibration":        {{"appSetting", "vibration", true}},
	"app.dashboardWidgets": {{"appSetting", "dashboardWidgets", nil}},
}

// viewChoices lists the values each view key accepts.
var viewChoices = map[string][]string{
	"view.proxies.type":        {"list", "tab"},
	"view.proxies.sort":        {"none", "delay", "name"},
	"view.proxies.layout":      {"loose", "standard", "tight"},
	"view.proxies.icon":        {"filled", "plain", "hidden"},
	"view.proxies.card":        {"loose", "standard", "compact", "oneline"},
	"view.proxies.hidetimeout": {"true", "false"},
	"view.app.theme":           {"auto", "system", "light", "dark"},
	"view.app.navbar":          {"floating", "docked"},
	"view.app.tabs":            {"slide", "fade"},
	"view.app.glass":           {"none", "standard", "ultra"},
	"view.app.black":           {"true", "false"},
	"app.style":                {"vivid", "tinted", "soft", "monochrome"},
}

// headerBackup is one setting's own value while a panel header holds it.
type headerBackup struct {
	Present bool            `json:"present"`
	Value   json.RawMessage `json:"value,omitempty"`
}

// settingsWriter collects a customization before it is persisted, remembering
// the user's own value of every setting a header holds.
type settingsWriter struct {
	settings    map[string]profiles.Object
	owned       map[string]bool
	panelSet    []string
	backup      map[string]headerBackup
	writes      map[string]map[string]any
	active      map[string]map[string]bool
	keys        []string
	touched     map[string]bool
	specialKeys map[string]bool
	forcedKeys  map[string]bool
}

func newSettingsWriter(catalog profiles.Document, app profiles.Object) *settingsWriter {
	w := &settingsWriter{
		settings: map[string]profiles.Object{
			"appSetting": app,
		},
		owned:       map[string]bool{},
		backup:      map[string]headerBackup{},
		writes:      map[string]map[string]any{},
		active:      map[string]map[string]bool{},
		touched:     map[string]bool{},
		specialKeys: map[string]bool{},
		forcedKeys:  map[string]bool{},
	}
	for _, name := range []string{"proxiesStyle", "themeProps"} {
		object := profiles.Object{}
		_ = json.Unmarshal(catalog.Settings[name], &object)
		w.settings[name] = object
	}
	if w.settings["appSetting"] == nil {
		w.settings["appSetting"] = profiles.Object{}
	}
	var owned []string
	_ = json.Unmarshal(app["ownedSettings"], &owned)
	for _, key := range owned {
		w.owned[key] = true
	}
	_ = json.Unmarshal(app["panelSetSettings"], &w.panelSet)
	_ = json.Unmarshal(app["headerBackup"], &w.backup)
	return w
}

func (w *settingsWriter) set(key, field string, value any) {
	if w.writes[key] == nil {
		w.writes[key] = map[string]any{}
	}
	if w.active[key] == nil {
		w.active[key] = map[string]bool{}
		w.keys = append(w.keys, key)
	}
	w.writes[key][field] = value
	w.active[key][field] = true
}

// setPaletteColor offers the panel's colour among the theme's swatches.
func (w *settingsWriter) setPaletteColor(color uint64) {
	raw := w.settings["themeProps"]["primaryColors"]
	colors := []uint64{}
	if len(raw) == 0 {
		// No saved palette yet: the provider colour joins the defaults.
		colors = defaultProviderPrimaryColors()
	} else {
		_ = json.Unmarshal(raw, &colors)
	}
	if !slices.Contains(colors, color) {
		colors = append(colors, color)
	}
	w.set("view.app.color", "primaryColors", colors)
}

func (w *settingsWriter) setWidgets(widgets []string, denied bool) {
	if len(widgets) == 0 {
		return
	}
	if denied {
		if _, ok := w.backup["appSetting.dashboardWidgets"]; !ok {
			w.remember("appSetting", "dashboardWidgets")
		}
		w.backup[forcedWidgetsBackup] = headerBackup{Present: true, Value: jsonValue(true)}
		w.settings["appSetting"]["dashboardWidgets"] = jsonValue(widgets)
		w.touched["appSetting"] = true
		// The panel's cards stand even over the user's until it stops denying.
		w.set(providerWidgetsSetting, "dashboardWidgets", widgets)
		w.forcedKeys[providerWidgetsSetting] = true
		if !slices.Contains(w.panelSet, providerWidgetsSetting) {
			w.panelSet = append(w.panelSet, providerWidgetsSetting)
		}
		return
	}
	if w.owned[providerWidgetsSetting] {
		w.forget(providerWidgetsSetting)
		return
	}
	w.set(providerWidgetsSetting, "dashboardWidgets", widgets)
}

// releaseForcedWidgets puts the user's cards back after denywidgets stops,
// whether or not the user owns them.
func (w *settingsWriter) releaseForcedWidgets() {
	forced, ok := w.backup[forcedWidgetsBackup]
	if !ok || !forced.Present {
		return
	}
	delete(w.backup, forcedWidgetsBackup)
	w.restore("appSetting", "dashboardWidgets")
	w.panelSet = slices.DeleteFunc(w.panelSet, func(item string) bool { return item == providerWidgetsSetting })
}

func (w *settingsWriter) applyView(headers map[string]string) {
	for _, entry := range strings.Split(profiles.ProviderHeader(headers, "view"), ";") {
		key, value, ok := strings.Cut(entry, ":")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.ToLower(strings.TrimSpace(value))
		if !strings.Contains(key, ".") {
			key = "proxies." + key
		}
		if key == "app.board" {
			// The extended board is gone; an older panel's key is ignored.
			continue
		}
		switch key {
		case "app.color":
			if color, ok := viewColor(value); ok {
				w.set("view.app.color", "primaryColor", color)
				w.setPaletteColor(color)
			}
			continue
		case "app.style":
			if slices.Contains(viewChoices["app.style"], value) {
				w.set("view.app.color", "colorStyle", value)
			}
			continue
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
			case "min":
				value = "oneline"
			}
		}
		canonical := canonicalViewKey(key)
		fields, known := viewKeyFields[canonical]
		if !known || !slices.Contains(viewChoices[canonical], value) {
			continue
		}
		switch canonical {
		case "view.app.navbar":
			w.set(canonical, fields[0].field, value == "floating")
		case "view.app.black", "view.proxies.hidetimeout":
			w.set(canonical, fields[0].field, value == "true" || value == "yes" || value == "1")
		case "view.app.theme":
			mode := map[string]string{"auto": "system", "system": "system", "light": "light", "dark": "dark"}[value]
			if mode != "" {
				w.set(canonical, fields[0].field, mode)
			}
		default:
			w.set(canonical, fields[0].field, value)
		}
	}
}

func (w *settingsWriter) applySpecials(headers map[string]string) {
	// A special flag holds its setting while the panel sends it and gives it
	// back to the user's own value once it stops, unless the user took it over.
	w.special("app.hideIp", profiles.ProviderSpecial(headers, "hideip"), true)
	w.special("app.vibration", profiles.ProviderSpecial(headers, "novibrate"), false)
}

func (w *settingsWriter) special(key string, said, on bool) {
	w.specialKeys[key] = true
	field := strings.TrimPrefix(key, "app.")
	name := "appSetting." + field
	if entry, ok := w.backup[name]; ok {
		var saved bool
		if !entry.Present || json.Unmarshal(entry.Value, &saved) != nil {
			delete(w.backup, name)
			w.touched["appSetting"] = true
		}
	}
	if w.owned[key] {
		// The user's value stands; the marker stays so handing it back later
		// still clears what the panel once set.
		w.forget(key)
		return
	}
	if said {
		if _, ok := w.backup[name]; !ok {
			if slices.Contains(w.panelSet, key) {
				// A marker saved before backups existed was the panel's, not
				// the user's: the value it left is not a personal one.
				w.backup[name] = headerBackup{Present: true, Value: jsonValue(!on)}
			} else {
				w.remember("appSetting", field)
			}
		}
		w.settings["appSetting"][field] = jsonValue(on)
		w.touched["appSetting"] = true
		w.set(key, field, on)
		if !slices.Contains(w.panelSet, key) {
			w.panelSet = append(w.panelSet, key)
		}
		return
	}
	if !slices.Contains(w.panelSet, key) {
		if _, ok := w.backup[name]; !ok {
			return
		}
	}
	if entry, ok := w.backup[name]; ok {
		delete(w.backup, name)
		if entry.Present {
			w.settings["appSetting"][field] = entry.Value
		} else {
			delete(w.settings["appSetting"], field)
		}
	} else {
		w.settings["appSetting"][field] = jsonValue(!on)
	}
	w.panelSet = slices.DeleteFunc(w.panelSet, func(item string) bool { return item == key })
	w.touched["appSetting"] = true
}

func (w *settingsWriter) remember(setting, field string) {
	raw := w.settings[setting][field]
	if len(raw) == 0 {
		w.backup[setting+"."+field] = headerBackup{Present: false}
	} else {
		w.backup[setting+"."+field] = headerBackup{Present: true, Value: append(json.RawMessage(nil), raw...)}
	}
	w.touched["appSetting"] = true
}

func (w *settingsWriter) restore(setting, field string) {
	entry, ok := w.backup[setting+"."+field]
	if !ok {
		return
	}
	delete(w.backup, setting+"."+field)
	if entry.Present {
		w.settings[setting][field] = entry.Value
	} else {
		delete(w.settings[setting], field)
	}
	w.touched[setting] = true
}

// forget drops the user's saved value of a key the user now owns.
func (w *settingsWriter) forget(key string) {
	for _, field := range viewKeyFields[key] {
		if _, ok := w.backup[field.setting+"."+field.field]; ok {
			delete(w.backup, field.setting+"."+field.field)
			w.touched["appSetting"] = true
		}
	}
	delete(w.backup, key+".on")
}

func (w *settingsWriter) commit(ctx context.Context, app *App) error {
	sort.Strings(w.keys)
	for _, key := range w.keys {
		fields := viewKeyFields[key]
		if len(fields) == 0 || w.specialKeys[key] || w.forcedKeys[key] {
			continue
		}
		if w.owned[key] {
			w.forget(key)
			continue
		}
		for _, field := range fields {
			value, held := w.writes[key][field.field]
			if !held {
				continue
			}
			if _, ok := w.backup[field.setting+"."+field.field]; !ok {
				w.remember(field.setting, field.field)
			}
			w.settings[field.setting][field.field] = jsonValue(value)
			w.touched[field.setting] = true
		}
		if !slices.Contains(w.panelSet, key) {
			w.panelSet = append(w.panelSet, key)
		}
	}
	// A key the current profile no longer sends goes back to the user's own
	// value, or to its default when no backup was kept.
	kept := w.panelSet[:0]
	for _, key := range w.panelSet {
		if _, written := w.writes[key]; written || w.owned[key] {
			kept = append(kept, key)
			continue
		}
		// Only the fields the panel actually held have a backup; a key saved
		// before backups existed falls back to its defaults.
		restored := false
		for _, field := range viewKeyFields[key] {
			if _, ok := w.backup[field.setting+"."+field.field]; ok {
				w.restore(field.setting, field.field)
				restored = true
			}
		}
		if !restored {
			for _, field := range viewKeyFields[key] {
				if field.fallback != nil {
					w.settings[field.setting][field.field] = jsonValue(field.fallback)
					w.touched[field.setting] = true
				}
			}
		}
	}
	w.panelSet = kept
	return w.persist(ctx, app)
}

func (w *settingsWriter) persist(ctx context.Context, app *App) error {
	patch := profiles.Object{}
	if len(w.panelSet) > 0 || w.touched["appSetting"] {
		settings := w.settings["appSetting"]
		settings["panelSetSettings"] = jsonValue(w.panelSet)
		if len(w.backup) > 0 {
			settings["headerBackup"] = jsonValue(w.backup)
		} else {
			delete(settings, "headerBackup")
		}
		w.settings["appSetting"] = settings
		w.touched["appSetting"] = true
	}
	for name, object := range w.settings {
		if !w.touched[name] {
			continue
		}
		patch[name] = jsonValue(object)
	}
	if len(patch) == 0 {
		return nil
	}
	return app.patchSettings(ctx, patch, 0)
}

func canonicalViewKey(key string) string {
	key = strings.ToLower(strings.TrimSpace(key))
	if strings.HasPrefix(key, "view.app.") || strings.HasPrefix(key, "view.proxies.") {
		return key
	}
	if strings.HasPrefix(key, "app.") || strings.HasPrefix(key, "proxies.") {
		return "view." + key
	}
	return key
}

func viewColor(value string) (uint64, bool) {
	hex := strings.TrimPrefix(value, "#")
	upper := strings.ToUpper(hex)
	if len(upper) != 6 && len(upper) != 8 {
		return 0, false
	}
	if _, err := strconv.ParseUint(upper, 16, 64); err != nil {
		return 0, false
	}
	if len(upper) == 6 {
		upper = "FF" + upper
	}
	color, err := strconv.ParseUint(upper, 16, 32)
	return color, err == nil
}
