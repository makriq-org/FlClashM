//go:build linux || android

package transport

import (
	"os/exec"
	"syscall"
)

// Linux's parent-death signal follows the creating OS thread. The adapter pins
// that thread until Wait completes, tying children to the service process.
func bindChildLifetime(command *exec.Cmd) bool {
	command.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	return true
}
