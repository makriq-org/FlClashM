package service

import (
	"context"
	"encoding/json"
	"errors"

	"core/backend"
)

// Cache changes are engine effects, never a second runtime controller. The
// adapter owns its internal handles and must retain files pinned by live plans
// or nodes. Callers can name a profile, never a filesystem location.
func (a *App) cacheCommand(ctx context.Context, method string, params json.RawMessage, id string) (Receipt, error) {
	effect := "cache.clear"
	payload := json.RawMessage(`{}`)
	if method == "profile.clearCache" {
		var p struct {
			ProfileID string `json:"profileId"`
		}
		if err := decodeParams(params, &p); err != nil {
			return Receipt{}, err
		}
		if _, err := a.profiles.Get(p.ProfileID); err != nil {
			return Receipt{}, err
		}
		payload = jsonValue(p)
	} else {
		if err := decodeParams(params, &struct{}{}); err != nil {
			return Receipt{}, err
		}
	}
	if method == "storage.collect" {
		effect = "cache.collect"
	}
	receipt, err := a.runtime.SubmitEngineCommand(runtimeID(id), backend.EngineCommand{Method: effect, Params: payload})
	result := Receipt{RuntimeOperationID: receipt.OperationID}
	if err != nil {
		return result, err
	}
	completed, err := a.runtime.Await(ctx, receipt.OperationID)
	if err != nil {
		return result, err
	}
	if completed.Status != "succeeded" {
		return result, errors.New(completed.Error)
	}
	if method == "storage.collect" {
		if err = a.profiles.CollectSources(ctx); err != nil {
			return result, err
		}
	}
	if method == "storage.clearCache" {
		if lists, ok := a.compiler.Lists.(interface{ Reset() }); ok {
			lists.Reset()
		}
	}
	result.Revision = a.profiles.Snapshot().Revision
	return result, nil
}
