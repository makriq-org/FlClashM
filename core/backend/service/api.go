package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"core/backend"
)

func (a *App) Handle(raw []byte) []byte {
	response := backend.Response{APIVersion: backend.APIVersion}
	fail := func(code, message string) []byte {
		response.Result = nil
		response.Error = &backend.APIError{Code: code, Message: message}
		encoded, _ := json.Marshal(response)
		return encoded
	}
	if len(raw) > backend.MaxRequestBytes {
		return fail("request_too_large", "request exceeds size limit")
	}
	var request backend.Request
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if !utf8.Valid(raw) || !json.Valid(raw) || decoder.Decode(&request) != nil {
		return fail("invalid_request", "invalid backend request")
	}
	response.OperationID = request.OperationID
	if request.APIVersion != backend.APIVersion {
		return fail("unsupported_version", "unsupported API version")
	}
	if len(request.OperationID) < 1 || len(request.OperationID) > 128 {
		return fail("invalid_request", "operationId must contain 1..128 bytes")
	}
	if a.ctx.Err() != nil {
		return fail("backend_closed", "backend is closing")
	}
	var err error
	switch request.Method {
	case "snapshot":
		response.Result = a.Snapshot()
	case "settings.get":
		var raw json.RawMessage
		raw, err = a.ExportSettings()
		response.Result = raw
	case "profile.get":
		var params struct {
			ProfileID string `json:"profileId"`
		}
		if err = decodeParams(request.Input, &params); err == nil {
			var value any
			value, err = a.profileResult(params.ProfileID)
			response.Result = value
		}
	case "operation.get", "operation.cancel":
		var params struct {
			OperationID string `json:"operationId"`
		}
		if err = decodeParams(request.Input, &params); err != nil || params.OperationID == "" {
			return fail("invalid_request", "target operationId is required")
		}
		if request.Method == "operation.get" {
			var receipt Receipt
			receipt, err = a.operations.get(params.OperationID)
			if err == nil {
				response.Result = receipt
			} else {
				response.Result, err = a.runtime.Operation(params.OperationID)
			}
		} else {
			cancelled := a.operations.cancel(params.OperationID)
			if !cancelled {
				cancelled = a.runtime.Cancel(params.OperationID)
			}
			response.Result = cancelled
		}
	case "blob.create":
		response.Result, err = a.newBlob()
	case "blob.append":
		var params struct {
			Token  string `json:"token"`
			Offset int64  `json:"offset"`
			Data   string `json:"data"`
		}
		if err = decodeParams(request.Input, &params); err == nil {
			response.Result, err = a.appendBlob(a.ctx, params.Token, params.Offset, params.Data)
		}
	case "blob.read":
		var params struct {
			Token  string `json:"token"`
			Offset int64  `json:"offset"`
			Limit  int    `json:"limit"`
		}
		if err = decodeParams(request.Input, &params); err == nil {
			response.Result, err = a.readBlob(params.Token, params.Offset, params.Limit)
		}
	case "blob.delete":
		var params struct {
			Token string `json:"token"`
		}
		if err = decodeParams(request.Input, &params); err == nil {
			err = a.removeBlob(params.Token)
			response.Result = err == nil
		}
	case "capabilities":
		response.Result = map[string]any{"apiVersion": backend.APIVersion, "storageVersion": dataVersion, "platform": a.compiler.Capabilities.Platform, "transports": []string{"naiveproxy", "olcrtc", "byedpi", "stormdns"}}
	default:
		if strings.HasPrefix(request.Method, "runtime.") {
			response.Result, err = a.runtimeCommand(request)
		} else {
			response.Result, err = a.submit(request)
		}
	}
	if err != nil {
		return fail("command_rejected", err.Error())
	}
	encoded, _ := json.Marshal(response)
	return encoded
}
func decodeParams(raw []byte, out any) error {
	if len(raw) == 0 {
		raw = json.RawMessage(`{}`)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if !json.Valid(raw) {
		return errors.New("invalid command parameters")
	}
	return decoder.Decode(out)
}
func (a *App) profileResult(id string) (any, error) {
	record, err := a.profiles.Get(id)
	if err != nil {
		return nil, err
	}
	return struct {
		Metadata any    `json:"metadata"`
		Source   string `json:"source"`
		Revision uint64 `json:"revision"`
		Digest   string `json:"digest"`
	}{record.Metadata, record.Source, record.Revision, record.Digest}, nil
}
func (a *App) runtimeCommand(request backend.Request) (backend.Receipt, error) {
	if _, err := a.operations.get(request.OperationID); err == nil {
		return backend.Receipt{}, errors.New("operationId belongs to an application command")
	}
	if err := decodeParams(request.Input, &struct{}{}); err != nil {
		return backend.Receipt{}, err
	}
	method := ""
	var input backend.Input
	switch request.Method {
	case "runtime.start":
		method = "connect"
	case "runtime.apply":
		method = "apply"
	case "runtime.restart":
		method = "restart"
	case "runtime.stop":
		method = "stop"

	case "runtime.recover":
		method = "recover"
	default:
		return backend.Receipt{}, errors.New("unsupported runtime command")
	}
	// A retry must return the original outcome even if subscriptions changed the
	// current source after that command accepted its immutable input.
	if receipt, err := a.runtime.Operation(request.OperationID); err == nil {
		if receipt.Method != "" && receipt.Method != method {
			return backend.Receipt{}, errors.New("operationId reused for a different command")
		}
		return receipt, nil
	}
	if method == "stop" {
		if err := a.operations.disableBootstrap(); err != nil {
			return backend.Receipt{}, err
		}
	}
	if method == "apply" || method == "connect" || method == "restart" {
		var err error
		input, err = a.captureInput()
		if err != nil {
			return backend.Receipt{}, err
		}
	}
	return a.runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: request.OperationID, Method: method, Input: input})
}
func (a *App) submit(request backend.Request) (Receipt, error) {
	switch request.Method {
	case "settings.patch", "profile.put", "profile.delete", "profile.select", "profile.reorder", "profile.validate", "subscription.refresh", "profile.import.url", "profile.import.file", "backup.export", "backup.restore":
	default:
		return Receipt{}, errors.New("unsupported application command")
	}
	if _, err := a.runtime.Operation(request.OperationID); err == nil {
		return Receipt{}, errors.New("operationId belongs to a runtime command")
	}
	operation, receipt, err := a.operations.accept(a.ctx, request.OperationID, request.Method, request.Input)
	if err != nil || operation == nil {
		return receipt, err
	}
	params := bytes.Clone(request.Input)
	a.workers.Go(func() {
		result, err := a.perform(operation.ctx, request.Method, params, operation.receipt.OperationID)
		a.operations.finish(operation, result, err)
		a.publish()
	})
	return receipt, nil
}
func (a *App) submitInternal(method string, params any) (Receipt, error) {
	raw, err := json.Marshal(params)
	if err != nil {
		return Receipt{}, err
	}
	return a.submit(backend.Request{APIVersion: backend.APIVersion, OperationID: newID("scheduled"), Method: method, Input: raw})
}
func (a *App) Await(ctx context.Context, id string) (Receipt, error) {
	a.operations.mu.Lock()
	op := a.operations.running[id]
	a.operations.mu.Unlock()
	if op == nil {
		return a.operations.get(id)
	}
	select {
	case <-ctx.Done():
		return Receipt{}, ctx.Err()
	case <-op.done:
		return a.operations.get(id)
	}
}
