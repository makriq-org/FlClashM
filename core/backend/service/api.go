package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"core/backend"
	"core/backend/authoring"
	"core/backend/compile"
	"core/backend/profiles"
	"time"
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
	if a.resetting.Load() && (strings.HasPrefix(request.Method, "blob.") && request.Method != "blob.read" || request.Method == "engine.command") {
		return fail("reset_in_progress", "data reset in progress")
	}
	if a.ctx.Err() != nil {
		response.Result = nil
		response.Error = &backend.APIError{Code: "backend_closed", Message: "backend is closing", ErrorCode: backend.ErrorCodeClosed}
		encoded, _ := json.Marshal(response)
		return encoded
	}
	var err error
	switch request.Method {
	case "authoring.snapshot":
		response.Result = a.profiles.AuthoringSnapshot()
	case "authoring.evaluate":
		var p struct {
			Script string         `json:"script"`
			Config compile.Object `json:"config"`
		}
		if err = decodeParams(request.Input, &p); err == nil {
			if p.Config == nil {
				err = errors.New("config object is required")
			} else {
				var config compile.Object
				config, err = (compile.JavaScript{Timeout: 2 * time.Second}).Evaluate(a.ctx, p.Script, p.Config)
				response.Result = map[string]any{"config": config}
			}
		}
	case "authoring.parseLinks":
		var p struct {
			Source string `json:"source"`
			Token  string `json:"token"`
		}
		if err = decodeParams(request.Input, &p); err == nil {
			var source string
			source, err = a.readSource(a.ctx, sourceParams{Source: p.Source, Token: p.Token})
			if err == nil {
				var proxies []compile.Object
				proxies, err = a.compiler.ParseLinks(a.ctx, source)
				response.Result = map[string]any{"proxies": proxies}
			}
		}
	case "authoring.resource.read":
		var p struct {
			Collection string          `json:"collection"`
			ID         json.RawMessage `json:"id"`
		}
		if err = decodeParams(request.Input, &p); err == nil {
			response.Result, err = a.readResource(a.ctx, p.Collection, authoring.ID(p.ID))
		}
	case "resource.get":
		var p struct {
			Collection string          `json:"collection"`
			ID         json.RawMessage `json:"id"`
		}
		if err = decodeParams(request.Input, &p); err == nil {
			var row authoring.Object
			var rev uint64
			row, rev, err = a.profiles.Resource(a.ctx, p.Collection, authoring.ID(p.ID))
			response.Result = map[string]any{"revision": rev, "declaration": row}
		}
	case "profile.validate":
		var fields map[string]json.RawMessage
		_ = json.Unmarshal(request.Input, &fields)
		if _, preview := fields["ageSecretKey"]; preview {
			var p sourceParams
			if err = decodeParams(request.Input, &p); err == nil {
				response.Result = a.validatePreview(a.ctx, p)
			}
		} else {
			response.Result, err = a.submit(request)
		}
	case "presentation":
		response.Result = a.Presentation()
	case "snapshot":
		response.Result = a.Snapshot()
	case "settings.get":
		var raw json.RawMessage
		raw, err = a.ExportSettings()
		response.Result = raw
	case "engine.command":
		var command backend.EngineCommand
		if err = decodeParams(request.Input, &command); err == nil {
			if _, exists := a.operations.get(request.OperationID); exists == nil {
				err = errors.New("operationId belongs to an application command")
			} else {
				response.Result, err = a.runtime.SubmitEngineCommand(request.OperationID, command)
			}
		}
	case "profile.get":
		var params struct {
			ProfileID string `json:"profileId"`
		}
		if err = decodeParams(request.Input, &params); err == nil {
			var value any
			value, err = a.profileResult(params.ProfileID)
			response.Result = value
		}
	case "profile.inspect":
		var params struct {
			ProfileID string `json:"profileId"`
		}
		if err = decodeParams(request.Input, &params); err == nil {
			record, readErr := a.profiles.Get(params.ProfileID)
			if readErr != nil {
				err = readErr
			} else {
				var captured []byte
				captured, err = a.captureProfileInput(&params.ProfileID)
				if err == nil {
					response.Result, err = a.compiler.InspectProfile(a.ctx, captured)
				}
				_ = record
			}
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
			if receipt, lookupErr := a.operations.get(params.OperationID); lookupErr == nil && receipt.RuntimeOperationID != "" {
				cancelled = a.runtime.Cancel(receipt.RuntimeOperationID) || cancelled
			}
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
	case "runtime.view":
		response.Result, err = a.RuntimeView()
	default:
		if strings.HasPrefix(request.Method, "runtime.") {
			if a.shouldDeferRuntime(request) {
				response.Result, err = a.deferredRuntime(request)
			} else {
				response.Result, err = a.runtimeCommand(request)
			}
		} else {
			response.Result, err = a.submit(request)
		}
	}
	if err != nil {
		response.Result = nil
		response.Error = &backend.APIError{Code: "command_rejected", Message: err.Error(), ErrorCode: backend.ErrorCode(err), ErrorDetails: backend.FailureDetails(err)}
		encoded, _ := json.Marshal(response)
		return encoded
	}
	encoded, _ := json.Marshal(response)
	return encoded
}

// RuntimeView is a read-only copy of the committed payload for local UI
// projection. Events deliberately contain no source or engine credentials.
func (a *App) RuntimeView() (json.RawMessage, error) {
	plan, _, err := a.runtime.Applied()
	if err != nil || plan == nil {
		return nil, err
	}
	return plan.Payload(), nil
}
func (a *App) AwaitRuntime(ctx context.Context, id string) (backend.Receipt, error) {
	return a.runtime.Await(ctx, id)
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
	if a.resetting.Load() {
		return backend.Receipt{}, errors.New("data reset in progress")
	}
	if _, err := a.operations.get(request.OperationID); err == nil {
		return backend.Receipt{}, errors.New("operationId belongs to an application command")
	}
	if err := decodeParams(request.Input, &struct{}{}); err != nil {
		return backend.Receipt{}, err
	}
	generation := a.runtime.Snapshot().Generation
	method := ""
	var input backend.Input
	switch request.Method {
	case "runtime.toggle":
		if a.runtime.Snapshot().DesiredRunning {
			method = "stop"
		} else {
			method = "connect"
		}
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
		if receipt.Method != "" && receipt.Method != method && request.Method != "runtime.toggle" {
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
		if method == "connect" || a.runtime.Snapshot().DesiredRunning {
			var captured compile.Input
			_ = json.Unmarshal(input, &captured)
			if captured.Profile == nil {
				return backend.Receipt{}, errors.New("no profile selected")
			}
		}
	}
	if request.Method == "runtime.toggle" || method == "apply" || method == "connect" || method == "restart" {
		return a.runtime.SubmitAtGeneration(backend.Request{APIVersion: backend.APIVersion, OperationID: request.OperationID, Method: method, Input: input}, generation)
	}
	return a.runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: request.OperationID, Method: method, Input: input})
}
func (a *App) submit(request backend.Request) (Receipt, error) {
	if a.resetting.Load() {
		return Receipt{}, errors.New("data reset in progress")
	}
	switch request.Method {
	case "storage.clearCache", "storage.collect", "profile.clearCache", "authoring.replace", "authoring.import", "authoring.resource.update", "resource.put", "resource.refresh", "profile.render", "subscription.update", "ui.attach", "ui.detach", "data.reset", "settings.patch", "profile.put", "profile.delete", "profile.select", "profile.reorder", "profile.validate", "profile.export", "proxy.select", "subscription.refresh", "profile.import.url", "profile.import.file", "backup.export", "backup.restore":
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
	ctx := operation.ctx
	if request.Method == "ui.attach" || request.Method == "ui.detach" {
		// Workers may run out of order; the runtime ignores an older UI fact.
		ctx = context.WithValue(ctx, uiSequenceKey{}, a.uiSequence.Add(1))
	}
	a.workers.Go(func() {
		result, err := a.perform(ctx, request.Method, params, operation.receipt.OperationID)
		if errors.Is(err, profiles.ErrConflict) {
			err = backend.WithFailure(err, "conflict", nil)
		}
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
