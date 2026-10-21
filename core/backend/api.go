package backend

import (
	"bytes"
	"encoding/json"
	"errors"
)

const MaxRequestBytes = 16 << 20

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type Response struct {
	APIVersion  int       `json:"apiVersion"`
	OperationID string    `json:"operationId"`
	Result      any       `json:"result,omitempty"`
	Error       *APIError `json:"error,omitempty"`
}

func (b *Backend) Operation(id string) (Receipt, error) {
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	if e := c.executions[id]; e != nil {
		return e.receipt, nil
	}
	for _, r := range c.document.Receipts {
		if r.OperationID == id {
			return r, nil
		}
	}
	return Receipt{}, errors.New("unknown operation")
}

// Handle is a transport-independent JSON boundary. Submission is asynchronous;
// callers observe operation receipts and snapshots without owning their lifetime.
func (b *Backend) Handle(raw []byte) []byte {
	response := Response{APIVersion: APIVersion}
	fail := func(code, message string) []byte {
		response.Error = &APIError{code, message}
		response.Result = nil
		result, _ := json.Marshal(response)
		return result
	}
	if len(raw) > MaxRequestBytes {
		return fail("request_too_large", "request exceeds size limit")
	}
	var request Request
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if !json.Valid(raw) || decoder.Decode(&request) != nil {
		return fail("invalid_request", "invalid backend request")
	}
	response.OperationID = request.OperationID
	if request.APIVersion != APIVersion {
		return fail("unsupported_version", "unsupported API version")
	}
	if len(request.OperationID) < 1 || len(request.OperationID) > 128 {
		return fail("invalid_request", "operationId must contain 1..128 bytes")
	}
	var err error
	switch request.Method {
	case "snapshot":
		if len(request.Input) > 0 {
			return fail("invalid_request", "snapshot does not accept params")
		}
		response.Result = b.Snapshot()
	case "operation.get", "operation.cancel":
		var params struct {
			OperationID string `json:"operationId"`
		}
		if json.Unmarshal(request.Input, &params) != nil || params.OperationID == "" {
			return fail("invalid_request", "target operationId is required")
		}
		if request.Method == "operation.get" {
			response.Result, err = b.Operation(params.OperationID)
		} else {
			response.Result = b.Cancel(params.OperationID)
		}
	default:
		response.Result, err = b.Submit(request)
	}
	if err != nil {
		return fail("command_rejected", err.Error())
	}
	result, _ := json.Marshal(response)
	return result
}

// Applied returns immutable copies for backend application services. Source
// input and compiled credentials are never included in public runtime events.
func (b *Backend) Applied() (*RuntimePlan, Input, error) {
	c := b.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.document.Applied == nil {
		return nil, nil, nil
	}
	plan, err := RestorePlan(c.document.Applied.Plan)
	return plan, bytes.Clone(c.document.Applied.Input), err
}
