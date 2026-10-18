//go:build !android || !cmfa

package main

import (
	"context"
	"errors"
)

// Root composition is Android-only; portable behavior is exercised through
// injected hosts in core/backend. This is not a desktop composition root.
func (backendEngine) SystemDNS(context.Context, []string) error {
	return errors.New("Android system DNS mechanism is unavailable on this host")
}
