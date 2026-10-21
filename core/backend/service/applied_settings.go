package service

import (
	"bytes"
	"context"
	"encoding/json"

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
	patch := profiles.Object{}
	for _, key := range []string{"ipv6", "allow-lan", "mixed-port", "find-process-mode", "mode"} {
		if raw := applied.Patch[key]; len(raw) > 0 && !bytes.Equal(raw, current[key]) {
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
