package service

import (
	"bytes"
	"context"
	"encoding/json"
	"slices"

	"core/backend/compile"
	"core/backend/profiles"
)

// Legacy Flutter retained resolved network hints as the next profile's
// fallback. Preserve that behavior after successful application, with a catalog
// revision fence so a late result cannot overwrite a newer user edit.
func (a *App) retainAppliedSettings(ctx context.Context) {
	plan, input, err := a.runtime.Applied()
	if err != nil || plan == nil {
		return
	}
	var captured compile.Input
	if json.Unmarshal(input, &captured) != nil {
		return
	}
	catalog := a.profiles.Snapshot()
	if captured.CatalogRevision != catalog.Revision {
		return
	}
	var applied struct {
		Patch profiles.Object `json:"patch"`
	}
	if json.Unmarshal(plan.Payload(), &applied) != nil {
		return
	}
	var current profiles.Object
	_ = json.Unmarshal(catalog.Settings["patchClashConfig"], &current)
	var appSettings struct {
		OwnedSettings []string `json:"ownedSettings"`
	}
	appSettingsRaw, _ := json.Marshal(captured.Settings["appSetting"])
	_ = json.Unmarshal(appSettingsRaw, &appSettings)
	ownsMixedPort := slices.Contains(appSettings.OwnedSettings, "clash.mixed-port")
	var headers map[string]string
	if captured.Profile != nil {
		raw, _ := json.Marshal(captured.Profile.Metadata["providerHeaders"])
		_ = json.Unmarshal(raw, &headers)
	}
	patch := profiles.Object{}
	for _, key := range []string{"ipv6", "allow-lan", "mixed-port", "find-process-mode", "mode"} {
		if key == "mode" && profiles.ProviderSpecial(headers, "noglobal") {
			// A temporary profile restriction must not replace the personal mode.
			continue
		}
		raw := applied.Patch[key]
		if key == "mixed-port" && a.compiler.Capabilities.Platform == "android" && !ownsMixedPort {
			var port int
			// Android's implicit zero is a runtime security policy, not a fallback
			// value to retain for the next profile.
			if json.Unmarshal(raw, &port) == nil && port == 0 {
				continue
			}
		}
		if len(raw) > 0 && !bytes.Equal(raw, current[key]) {
			patch[key] = raw
		}
	}
	var currentTun, resolvedTun profiles.Object
	_ = json.Unmarshal(current["tun"], &currentTun)
	_ = json.Unmarshal(applied.Patch["tun"], &resolvedTun)
	if raw := resolvedTun["stack"]; len(raw) > 0 && !bytes.Equal(raw, currentTun["stack"]) {
		patch["tun"] = jsonValue(profiles.Object{"stack": raw})
	}
	if len(patch) == 0 {
		return
	}
	_ = a.patchSettings(ctx, profiles.Object{"patchClashConfig": jsonValue(patch)}, catalog.Revision)
}
