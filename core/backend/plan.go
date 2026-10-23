// Package backend contains the portable application backend. Platform and engine
// integration belongs to adapters; this package has no Android or UI dependency.
package backend

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
)

const APIVersion = 1
const StorageVersion = 1
const PlanVersion = 1

// Input is the complete, persisted preparation input. The compiler owns its
// interpretation. It must contain source data, never an executable client plan.
type Input = json.RawMessage

// PlanData is the on-disk representation, not an execution capability. Loading
// it requires digest and version verification before constructing RuntimePlan.
type PlanData struct {
	Version    int             `json:"version"`
	Generation uint64          `json:"generation"`
	Digest     string          `json:"digest"`
	Payload    json.RawMessage `json:"payload"`
}

// RuntimePlan has no exported mutable fields. Each boundary receives its own
// copy of the serialized payload, including the adapter and persistence layers.
type RuntimePlan struct{ data PlanData }

func NewRuntimePlan(generation uint64, payload any) (*RuntimePlan, error) {
	if generation == 0 {
		return nil, errors.New("plan generation must be positive")
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	canonical, err := canonicalJSON(raw)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(canonical)
	return &RuntimePlan{PlanData{PlanVersion, generation, hex.EncodeToString(digest[:]), canonical}}, nil
}
func RestorePlan(data PlanData) (*RuntimePlan, error) {
	if data.Version != PlanVersion {
		return nil, fmt.Errorf("unsupported plan version %d", data.Version)
	}
	p, err := NewRuntimePlan(data.Generation, json.RawMessage(data.Payload))
	if err != nil {
		return nil, err
	}
	if p.Digest() != data.Digest {
		return nil, errors.New("plan digest mismatch")
	}
	return p, nil
}
func (p *RuntimePlan) Generation() uint64       { return p.data.Generation }
func (p *RuntimePlan) Digest() string           { return p.data.Digest }
func (p *RuntimePlan) Payload() json.RawMessage { return bytes.Clone(p.data.Payload) }
func (p *RuntimePlan) Data() PlanData           { d := p.data; d.Payload = p.Payload(); return d }

func canonicalJSON(raw []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var v any
	if err := decoder.Decode(&v); err != nil {
		return nil, err
	}
	if _, ok := v.(map[string]any); !ok {
		return nil, errors.New("expected JSON object")
	}
	// json.Valid also rejects trailing values. Top-level members are sorted so
	// a struct and a map with the same fields share one digest; nested values
	// keep member order: some engine maps (dns.nameserver-policy) are
	// evaluated in declaration order.
	if !json.Valid(raw) {
		return nil, errors.New("invalid JSON document")
	}
	var members map[string]json.RawMessage
	if err := json.Unmarshal(raw, &members); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(members))
	for key := range members {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var out bytes.Buffer
	out.WriteByte('{')
	for i, key := range keys {
		if i > 0 {
			out.WriteByte(',')
		}
		name, _ := json.Marshal(key)
		out.Write(name)
		out.WriteByte(':')
		if err := json.Compact(&out, members[key]); err != nil {
			return nil, err
		}
	}
	out.WriteByte('}')
	return out.Bytes(), nil
}

type Compiler interface {
	Compile(context.Context, Input, uint64) (*RuntimePlan, error)
}

// RuntimeDiagnostics is a trusted host sink, never a public API error. The host
// must redact messages before persisting them, just like transport stderr.
type RuntimeDiagnostics interface {
	RuntimeFailure(string, error)
}

type Observation struct {
	State   string `json:"state"` // stopped, running, unknown, degraded
	Message string `json:"message,omitempty"`
}

// Adapters implement mechanisms only. They must honor cancellation, must not
// retain mutable plan buffers and must not synchronously reenter the coordinator.
// A successful Stop must fence any prior asynchronous start before returning.
type EngineAdapter interface {
	Apply(context.Context, *RuntimePlan) error
	Start(context.Context) error
	Stop(context.Context) error
	Observe(context.Context) (Observation, error)
}
type TransportAdapter interface {
	Prepare(context.Context, *RuntimePlan) error
	Start(context.Context, *RuntimePlan) error
	Stop(context.Context) error
	Observe(context.Context) (Observation, error)
}

// EngineEraser clears resident configuration and auxiliary controllers after
// Stop when the user explicitly resets application data.
type EngineEraser interface{ Forget(context.Context) error }

type PlatformAdapter interface {
	Start(context.Context, *RuntimePlan) error
	Stop(context.Context) error
	Observe(context.Context) (Observation, error)
}

// OperationLifetime keeps a service host alive during preparation and plan
// replacement, before a VPN descriptor exists. It grants no execution rights.
type OperationLifetime interface {
	BeginOperation(context.Context, string) error
	EndOperation(context.Context, string) error
}

// SelectionAdapter changes selectors and display metadata without replacing
// engine configuration or platform resources. The coordinator only invokes it
// after proving that all other plan fields are identical.
type SelectionAdapter interface {
	ApplySelection(context.Context, *RuntimePlan, *RuntimePlan) error
}

type LiveSettingsAdapter interface {
	ApplyLiveSettings(context.Context, *RuntimePlan, *RuntimePlan) error
}

// EngineCommandAdapter exposes bounded engine mechanisms such as closing a
// connection or refreshing a provider. The coordinator serializes these effects
// with plan changes; adapters never receive another runtime owner.
type EngineCommand struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}
type EngineCommandAdapter interface {
	Command(context.Context, EngineCommand) error
}
