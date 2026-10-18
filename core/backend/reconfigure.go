package backend

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
)

func selectionOnly(previous, next *RuntimePlan) bool {
	strip := func(plan *RuntimePlan) ([]byte, error) {
		var data map[string]json.RawMessage
		if err := json.Unmarshal(plan.Payload(), &data); err != nil {
			return nil, err
		}
		delete(data, "selected-map")
		delete(data, "closeConnectionsOnSelect")
		if raw, ok := data["coreState"]; ok {
			var state map[string]json.RawMessage
			if err := json.Unmarshal(raw, &state); err != nil {
				return nil, err
			}
			delete(state, "current-profile-name")
			encoded, _ := json.Marshal(state)
			data["coreState"] = encoded
		}
		raw, _ := json.Marshal(data)
		return canonicalJSON(raw)
	}
	left, err := strip(previous)
	if err != nil {
		return false
	}
	right, err := strip(next)
	return err == nil && bytes.Equal(left, right)
}
func (c *runtimeCoordinator) trySelection(e *execution, previous Document, next *RuntimePlan, running bool) (bool, error) {
	updater, ok := c.engine.(SelectionAdapter)
	if !ok || previous.Applied == nil || previous.Applied.Running != running || next == nil || e.request.Method == "restart" {
		return false, nil
	}
	old, err := RestorePlan(previous.Applied.Plan)
	if err != nil {
		return false, err
	}
	if !selectionOnly(old, next) {
		return false, nil
	}
	if err = c.current(e); err != nil {
		return true, err
	}
	if running && c.nodeOptions != nil {
		var data struct {
			Selected map[string]string `json:"selected-map"`
		}
		_ = json.Unmarshal(next.Payload(), &data)
		for _, id := range c.nodeOrder {
			node := c.nodes[id]
			if node.awake || node.plan.Activation == nil || node.plan.Activation.Mode != "auto" {
				continue
			}
			selected := false
			for _, name := range data.Selected {
				selected = selected || name == node.plan.Name
			}
			if !selected {
				continue
			}
			if err = c.launchNode(e.ctx, node); err != nil {
				return true, err
			}
			healthy, checkErr := c.nodeOptions.Inspection.TestGroup(e.ctx, node.plan.Name, node.plan.Activation.Wake.URLs)
			if checkErr != nil || !healthy {
				return true, errors.Join(checkErr, errors.New("selected reserve node is not reachable"))
			}
		}
	}
	if err = updater.ApplySelection(e.ctx, old, next); err != nil {
		return true, err
	}
	var before, after struct {
		Selected map[string]string `json:"selected-map"`
		Close    bool              `json:"closeConnectionsOnSelect"`
	}
	_ = json.Unmarshal(old.Payload(), &before)
	_ = json.Unmarshal(next.Payload(), &after)
	if after.Close && !reflect.DeepEqual(before.Selected, after.Selected) {
		if commands, ok := c.engine.(EngineCommandAdapter); ok {
			if err = commands.Command(e.ctx, EngineCommand{Method: "connections.close"}); err != nil {
				return true, err
			}
		}
	}
	if err = c.current(e); err != nil {
		return true, err
	}
	return true, c.observe(e.ctx, running)
}

func liveSettingsOnly(previous, next *RuntimePlan) bool {
	keys := []string{"mode", "log-level", "tcp-concurrent", "unified-delay", "find-process-mode", "allow-lan", "mixed-port", "external-controller"}
	strip := func(plan *RuntimePlan) ([]byte, bool) {
		var payload map[string]json.RawMessage
		if json.Unmarshal(plan.Payload(), &payload) != nil {
			return nil, false
		}
		var state struct {
			VPN struct {
				SystemProxy bool `json:"systemProxy"`
			} `json:"vpn-props"`
		}
		_ = json.Unmarshal(payload["coreState"], &state)
		for _, section := range []string{"config", "patch"} {
			var fields map[string]json.RawMessage
			if json.Unmarshal(payload[section], &fields) != nil {
				return nil, false
			}
			for _, key := range keys {
				// A system proxy endpoint is baked into VpnService.Builder.
				if key == "mixed-port" && state.VPN.SystemProxy {
					continue
				}
				delete(fields, key)
			}
			payload[section], _ = json.Marshal(fields)
		}
		raw, err := json.Marshal(payload)
		if err != nil {
			return nil, false
		}
		return raw, true
	}
	left, ok := strip(previous)
	if !ok {
		return false
	}
	right, ok := strip(next)
	return ok && bytes.Equal(left, right)
}
func (c *runtimeCoordinator) tryLiveSettings(e *execution, previous Document, next *RuntimePlan, running bool) (bool, error) {
	adapter, ok := c.engine.(LiveSettingsAdapter)
	if !ok || previous.Applied == nil || previous.Applied.Running != running || next == nil || e.request.Method == "restart" {
		return false, nil
	}
	old, err := RestorePlan(previous.Applied.Plan)
	if err != nil {
		return false, err
	}
	if !liveSettingsOnly(old, next) {
		return false, nil
	}
	if err = c.current(e); err != nil {
		return true, err
	}
	if err = adapter.ApplyLiveSettings(e.ctx, old, next); err != nil {
		return true, err
	}
	if err = c.current(e); err != nil {
		return true, err
	}
	return true, c.observe(e.ctx, running)
}
