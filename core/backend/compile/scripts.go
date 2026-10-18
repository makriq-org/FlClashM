package compile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/dop251/goja"
)

// JavaScript runs one isolated preparation script with no filesystem, process,
// Android or network bindings. Its lifetime belongs to the backend operation.
type JavaScript struct{ Timeout time.Duration }

func (s JavaScript) Evaluate(ctx context.Context, source string, config Object) (Object, error) {
	timeout := s.Timeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	runtime := goja.New()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			runtime.Interrupt(ctx.Err())
		case <-done:
		}
	}()
	raw, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}
	// Construct a plain JS object; exposing a Go map would change JS property,
	// array and deletion semantics in existing scripts.
	if err = runtime.Set("__profileJSON", string(raw)); err != nil {
		return nil, err
	}
	_, err = runtime.RunString(`var console = {log:function(){},warn:function(){},error:function(){}};` + "\n" + source)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	value, err := runtime.RunString(`main(JSON.parse(__profileJSON))`)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	if promise, ok := value.Export().(*goja.Promise); ok {
		switch promise.State() {
		case goja.PromiseStateFulfilled:
			value = promise.Result()
		case goja.PromiseStateRejected:
			return nil, errors.New("profile script rejected: " + promise.Result().String())
		default:
			return nil, errors.New("profile script promise did not settle")
		}
	}
	if goja.IsNull(value) || goja.IsUndefined(value) {
		return config, nil
	}
	if err = runtime.Set("__profileResult", value); err != nil {
		return nil, err
	}
	encoded, err := runtime.RunString(`JSON.stringify(__profileResult)`)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewBufferString(encoded.String()))
	decoder.UseNumber()
	var result Object
	if err = decoder.Decode(&result); err != nil || result == nil {
		return nil, errors.New("profile script must return an object")
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return result, nil
}
