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
	// Settings stay raw so a change that only reorders an order-sensitive
	// dictionary (dns.nameserver-policy) is not mistaken for no change.
	type wireInput struct {
		Input
		Settings json.RawMessage `json:"settings"`
	}
	decode := func(raw backend.Input) (wireInput, error) {
		var value wireInput
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
	strip := func(value wireInput) []byte {
		value.CatalogRevision = 0
		value.Profile.Revision = 0
		delete(value.Profile.Metadata, "selectedMap")
		raw, _ := json.Marshal(value)
		return raw
	}
	if !bytes.Equal(strip(next), strip(old)) {
		return nil, nil
	}
	// The committed payload stays raw: decoding it into Go maps would lose the
	// member order of the engine configuration.
	var payload map[string]json.RawMessage
	if err = json.Unmarshal(plan.Payload(), &payload); err != nil {
		return nil, err
	}
	var config map[string]json.RawMessage
	_ = json.Unmarshal(payload["config"], &config)
	// Plans committed by the old compiler need a full rebuild after upgrade.
	if _, ok := config["rules"]; !ok {
		return nil, nil
	}
	var profileID *string
	if json.Unmarshal(payload["profileId"], &profileID) != nil || profileID == nil || *profileID != next.Profile.ID {
		return nil, nil
	}
	if payload["selected-map"], err = json.Marshal(selected); err != nil {
		return nil, err
	}
	return backend.NewRuntimePlan(generation, payload)
}
