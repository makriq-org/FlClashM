package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"

	"core/backend"
)

func (a *App) currentSourceMissing() bool {
	var id string
	_ = json.Unmarshal(a.profiles.Snapshot().Settings["currentProfileId"], &id)
	record, err := a.profiles.Get(id)
	return err == nil && record.SourceMissing
}
func (a *App) ensureCurrentSource(ctx context.Context) error {
	for range 8 {
		if err := ctx.Err(); err != nil {
			return err
		}
		var id string
		_ = json.Unmarshal(a.profiles.Snapshot().Settings["currentProfileId"], &id)
		if id == "" {
			return nil
		}
		record, err := a.profiles.Get(id)
		if err != nil {
			return err
		}
		if !record.SourceMissing {
			return nil
		}
		var address string
		_ = json.Unmarshal(record.Metadata["url"], &address)
		if address == "" {
			return errors.New("original profile file is missing")
		}
		if _, err = a.subscriptions.Update(ctx, id, a.deviceHeadersEnabled(true)); err != nil {
			return err
		}
	}
	return errors.New("profile selection changed during preparation")
}
func (a *App) shouldDeferRuntime(request backend.Request) bool {
	switch request.Method {
	case "runtime.start", "runtime.apply", "runtime.restart", "runtime.toggle":
	default:
		return false
	}
	if _, err := a.operations.get(request.OperationID); err == nil {
		return true
	}
	if request.Method == "runtime.toggle" && a.runtime.Snapshot().DesiredRunning {
		return false
	}
	return a.currentSourceMissing()
}

// Missing URL sources are fetched as a durable asynchronous application
// operation. No caller-owned context or Binder lifetime owns the download.
func (a *App) deferredRuntime(request backend.Request) (Receipt, error) {
	if a.resetting.Load() {
		return Receipt{}, errors.New("data reset in progress")
	}
	if err := decodeParams(request.Input, &struct{}{}); err != nil {
		return Receipt{}, err
	}
	if _, err := a.runtime.Operation(request.OperationID); err == nil {
		return Receipt{}, errors.New("operationId belongs to a runtime command")
	}
	op, receipt, err := a.operations.accept(a.ctx, request.OperationID, request.Method, bytes.Clone(request.Input))
	if err != nil || op == nil {
		return receipt, err
	}
	generation := a.runtime.Snapshot().Generation
	a.workers.Go(func() {
		result := Receipt{}
		err := a.ensureCurrentSource(op.ctx)
		if err == nil {
			err = op.ctx.Err()
		}
		if err == nil {
			a.runtimeMu.Lock()
			if a.resetting.Load() {
				err = errors.New("data reset in progress")
			} else {
				var input backend.Input
				input, err = a.captureInput()
				if err == nil {
					method := "apply"
					switch request.Method {
					case "runtime.start", "runtime.toggle":
						method = "connect"
					case "runtime.restart":
						method = "restart"
					}
					var runtimeReceipt backend.Receipt
					runtimeReceipt, err = a.runtime.SubmitAtGeneration(backend.Request{APIVersion: backend.APIVersion, OperationID: runtimeID(request.OperationID), Method: method, Input: input}, generation)
					result.RuntimeOperationID = runtimeReceipt.OperationID
					if op.ctx.Err() != nil && result.RuntimeOperationID != "" {
						a.runtime.Cancel(result.RuntimeOperationID)
						err = op.ctx.Err()
					}
				}
			}
			a.runtimeMu.Unlock()
		}
		a.operations.finish(op, result, err)
		a.publish()
	})
	return receipt, nil
}
