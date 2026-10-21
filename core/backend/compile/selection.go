package compile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"

	"core/backend"
)

// Selections do not participate in scripts, package expansion, transport
// compilation or engine validation. Reuse only the exact committed source and
// settings; subscriptions, editor changes and explicit restarts still prepare.
func (c *Compiler) CompileSelection(ctx context.Context, input, previous backend.Input, plan *backend.RuntimePlan, generation uint64) (*backend.RuntimePlan, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	decode := func(raw backend.Input) (Input, error) {
		var value Input
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		err := decoder.Decode(&value)
		return value, err
	}
	next, err := decode(input)
	if err != nil {
		return nil, err
	}
	old, err := decode(previous)
	if err != nil {
		return nil, err
	}
	if next.Version != 1 || old.Version != 1 || next.Profile == nil || old.Profile == nil || plan == nil {
		return nil, nil
	}
	selected := object(next.Profile.Metadata["selectedMap"])
	for _, value := range selected {
		if _, ok := value.(string); !ok {
			return nil, errors.New("profile selections must contain proxy names")
		}
	}
	strip := func(value Input) []byte {
		value.CatalogRevision = 0
		value.Profile.Revision = 0
		delete(value.Profile.Metadata, "selectedMap")
		raw, _ := json.Marshal(value)
		return raw
	}
	if !bytes.Equal(strip(next), strip(old)) {
		return nil, nil
	}
	var payload Object
	decoder := json.NewDecoder(bytes.NewReader(plan.Payload()))
	decoder.UseNumber()
	if err = decoder.Decode(&payload); err != nil {
		return nil, err
	}
	// Plans committed by the old compiler need a full rebuild after upgrade.
	if _, ok := object(payload["config"])["rules"]; !ok {
		return nil, nil
	}
	if payload["profileId"] != next.Profile.ID {
		return nil, nil
	}
	payload["selected-map"] = selected
	return backend.NewRuntimePlan(generation, payload)
}
