#!/usr/bin/env bash
# Verify the pinned CLI contract and every bundled/fallback strategy on the host.
set -euo pipefail
byedpi_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
byedpi_tmp="$(mktemp -d)"
trap 'rm -rf "$byedpi_tmp"' EXIT
byedpi_commit="$(sed -n "s/^const byedpiPinnedCommit = '\([0-9a-f]*\)';/\1/p" "$byedpi_root/lib/product/runtime/byedpi_release.dart")"
test "${#byedpi_commit}" -eq 40
if [ -n "${BYEDPI_SOURCE_DIR:-}" ]; then
  git -C "$BYEDPI_SOURCE_DIR" archive "$byedpi_commit" | tar -x -C "$byedpi_tmp"
else
  git init -q "$byedpi_tmp"
  git -C "$byedpi_tmp" fetch --depth 1 https://github.com/hufrea/byedpi.git "$byedpi_commit"
  git -C "$byedpi_tmp" checkout --detach FETCH_HEAD
fi
patch --batch --fuzz=0 -d "$byedpi_tmp" -p1 < "$byedpi_root/tool/patches/byedpi-android-ifaddrs.patch"
make -C "$byedpi_tmp"
cd "$byedpi_root/core"
BYEDPI_TEST_SOURCE="$byedpi_tmp" BYEDPI_TEST_BINARY="$byedpi_tmp/ciadpi" \
  go test ./backend/compile -run ByeDPI -count=1

# The host supplies libc interface enumeration; mask each API-24 symbol in turn
# to verify old Android fails only for interface names, without load-time imports.
cd "$byedpi_tmp"
"${CC:-cc}" -D_DEFAULT_SOURCE -D__ANDROID__ -D__ANDROID_API__=21 \
  -Ddlsym=byedpi_test_dlsym -Dmain=byedpi_main -I. -std=c99 -O2 \
  -c main.c -o compat_main.o
"${CC:-cc}" -D_DEFAULT_SOURCE -I. \
  "$byedpi_root/test/tool/byedpi_android_compat_test.c" \
  compat_main.o packets.o conev.o proxy.o desync.o mpool.o extend.o \
  -ldl -o compat_test
./compat_test
