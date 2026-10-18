package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"core/backend/profiles"
)

// Presentation is a read-only projection for native notifications, tiles and
// widgets. Reading it never starts, repairs or changes a runtime.
type Presentation struct {
	RequiresVPN       bool   `json:"requiresVpn"`
	HasActiveProfile  bool   `json:"hasActiveProfile"`
	Mode              string `json:"mode"`
	GlobalModeEnabled bool   `json:"globalModeEnabled"`
	NotificationTitle string `json:"notificationTitle"`
	AppliedGeneration uint64 `json:"appliedGeneration"`
}

func (a *App) Presentation() Presentation {
	catalog := a.profiles.Snapshot()
	var selected string
	_ = json.Unmarshal(catalog.Settings["currentProfileId"], &selected)
	value := Presentation{RequiresVPN: a.requiresVPN(), Mode: "rule", GlobalModeEnabled: true, NotificationTitle: "FlClashM", AppliedGeneration: a.runtime.Snapshot().AppliedGeneration}
	var metadata profiles.Object
	for _, record := range catalog.Profiles {
		var id string
		_ = json.Unmarshal(record.Metadata["id"], &id)
		if id == selected {
			value.HasActiveProfile = true
			metadata = record.Metadata
			break
		}
	}
	var patch struct {
		Mode string `json:"mode"`
	}
	_ = json.Unmarshal(catalog.Settings["patchClashConfig"], &patch)
	if patch.Mode != "" {
		value.Mode = patch.Mode
	}
	var headers map[string]string
	_ = json.Unmarshal(metadata["providerHeaders"], &headers)
	value.GlobalModeEnabled = !strings.EqualFold(strings.TrimSpace(profiles.ProviderHeader(headers, "globalmode")), "false")
	a.presentationMu.Lock()
	defer a.presentationMu.Unlock()
	if a.presentationGeneration != value.AppliedGeneration {
		plan, input, err := a.runtime.Applied()
		if err == nil && plan != nil {
			var captured struct {
				Profile *struct {
					ID       string          `json:"id"`
					Metadata profiles.Object `json:"metadata"`
				} `json:"profile"`
			}
			var prepared struct {
				Config struct {
					Mode   string `json:"mode"`
					Groups []struct {
						Name string `json:"name"`
					} `json:"proxy-groups"`
				} `json:"config"`
				Selected map[string]string `json:"selected-map"`
			}
			if json.Unmarshal(input, &captured) == nil && json.Unmarshal(plan.Payload(), &prepared) == nil {
				title := "FlClashM"
				group := ""
				if captured.Profile != nil {
					title = captured.Profile.ID
					var label string
					_ = json.Unmarshal(captured.Profile.Metadata["label"], &label)
					if label != "" {
						title = label
					}
					var appliedHeaders map[string]string
					_ = json.Unmarshal(captured.Profile.Metadata["providerHeaders"], &appliedHeaders)
					decode := func(key string) string { return decodeProviderHeader(profiles.ProviderHeader(appliedHeaders, key)) }
					if service := decode("servicename"); service != "" {
						title = service
					}
					group = decode("serverinfo")
				}
				a.presentationTitle = title
				a.presentationMode = prepared.Config.Mode
				a.presentationSelected = prepared.Selected
				a.presentationGroups = nil
				if group != "" {
					a.presentationGroups = append(a.presentationGroups, group)
				}
				a.presentationGroups = append(a.presentationGroups, "GLOBAL")
				for _, g := range prepared.Config.Groups {
					a.presentationGroups = append(a.presentationGroups, g.Name)
				}
				a.presentationGeneration = value.AppliedGeneration
			}
		}
	}
	if a.presentationGeneration != 0 {
		value.NotificationTitle = a.presentationTitle
		if a.presentationMode != "" {
			value.Mode = a.presentationMode
		}
		actual := map[string]string{}
		if a.inspection != nil {
			ctx, cancel := context.WithTimeout(a.ctx, time.Second)
			observed, err := a.inspection.Selected(ctx, a.presentationGroups)
			cancel()
			if err == nil {
				actual = observed
			}
		}
		for _, group := range a.presentationGroups {
			name := actual[group]
			if name == "" {
				name = a.presentationSelected[group]
			}
			seen := map[string]bool{}
			for name != "" && !seen[name] {
				seen[name] = true
				next := actual[name]
				if next == "" {
					next = a.presentationSelected[name]
				}
				if next == "" {
					break
				}
				name = next
			}
			if name != "" && name != "DIRECT" && name != "REJECT" {
				value.NotificationTitle += " / " + name
				break
			}
		}
	}
	return value
}

func (a *App) requiresVPN() bool {
	var props struct {
		Enable *bool `json:"enable"`
	}
	_ = json.Unmarshal(a.profiles.Snapshot().Settings["vpnProps"], &props)
	return props.Enable == nil || *props.Enable
}

// Headers historically accepted base64 (including URL-safe/padding-less forms)
// and fell back to the literal text when it was not valid UTF-8 base64.
func decodeProviderHeader(raw string) string {
	raw = strings.TrimSpace(raw)
	normalized, err := url.PathUnescape(raw)
	if err != nil {
		normalized = raw
	}
	for _, encoding := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		decoded, err := encoding.DecodeString(normalized)
		if err == nil && utf8.Valid(decoded) {
			return strings.TrimSpace(string(decoded))
		}
	}
	return raw
}
