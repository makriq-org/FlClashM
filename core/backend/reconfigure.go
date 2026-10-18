package backend

import (
	"bytes"
	"encoding/json"
	"errors"
)

func selectionOnly(previous, next *RuntimePlan) bool {
	strip := func(plan *RuntimePlan) ([]byte, error) {
		var data map[string]json.RawMessage
		if err := json.Unmarshal(plan.Payload(), &data); err != nil {
			return nil, err
		}
		delete(data, "selected-map")
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
	if err = c.current(e); err != nil {
		return true, err
	}
	return true, c.observe(e.ctx, running)
}
