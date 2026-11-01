package service

import (
	"context"
	"encoding/json"
	"time"

	"core/backend/compile"
	"core/backend/profiles"
)

// A pin may disappear inside mihomo after health checks. Persist that decision
// only for the exact applied input; an overlapping user choice wins by CAS.
func (a *App) reconcileProxyPins(ctx context.Context, read func(context.Context) (map[string]string, error)) {
	snapshot := a.runtime.Snapshot()
	if !snapshot.AppliedRunning || snapshot.Generation != snapshot.AppliedGeneration {
		return
	}
	plan, input, err := a.runtime.Applied()
	if err != nil || plan == nil || plan.Generation() != snapshot.AppliedGeneration {
		return
	}
	var captured compile.Input
	var prepared compile.Prepared
	if json.Unmarshal(input, &captured) != nil || captured.Profile == nil || json.Unmarshal(plan.Payload(), &prepared) != nil {
		return
	}
	catalog := a.profiles.Snapshot()
	var current string
	_ = json.Unmarshal(catalog.Settings["currentProfileId"], &current)
	if current != captured.Profile.ID {
		return
	}
	record, err := a.profiles.Get(current)
	if err != nil {
		return
	}
	selected := map[string]string{}
	_ = json.Unmarshal(record.Metadata["selectedMap"], &selected)
	fixed, err := read(ctx)
	if err != nil {
		return
	}
	changed := false
	for group, pin := range selected {
		if pin == "" || prepared.Selected[group] != pin {
			continue
		}
		manual := false
		for _, node := range prepared.Nodes {
			if node.Name == pin {
				manual = true
				break
			}
		}
		if manual {
			continue
		}
		if value, ok := fixed[group]; ok && value == "" {
			delete(selected, group)
			changed = true
		}
	}
	if !changed || a.runtime.Snapshot().Generation != snapshot.Generation || a.profiles.Snapshot().Revision != catalog.Revision {
		return
	}
	if _, err = a.profiles.UpdateMetadata(ctx, current, profiles.Object{"selectedMap": jsonValue(selected)}, record.Revision); err != nil {
		return
	}
	_, _ = a.applyCurrent(newID("reconcile-pins"), false)
	a.publish()
}

func (a *App) watchProxyPins(read func(context.Context) (map[string]string, error)) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-a.ctx.Done():
			return
		case <-ticker.C:
			a.reconcileProxyPins(a.ctx, read)
		}
	}
}
