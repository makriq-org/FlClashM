#!/usr/bin/env bash
set -euo pipefail

# Recreate dependencies from go.mod/go.sum; never modify the shared module cache.
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root/core"
go mod vendor
patch --batch --fuzz=0 -p1 < "$task_root/tool/patches/mihomo-mieru-terminal-timeout.patch"

# Test on the build host before cross-compiling the Android library.
env -u GOOS -u GOARCH -u GOARM -u CC -u CFLAGS CGO_ENABLED=0 \
  go test -mod=vendor ./vendor/github.com/enfein/mieru/v3/pkg/protocol \
  -run '^TestStreamUnderlayTerminalTimeout$' -count=1
