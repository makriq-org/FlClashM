//go:build !linux && !android

package transport

import "os/exec"

// Other hosts provide their platform lifetime mechanism behind this adapter;
// the portable coordinator does not depend on Linux process attributes.
func bindChildLifetime(command *exec.Cmd) bool { return false }
