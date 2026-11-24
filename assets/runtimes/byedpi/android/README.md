# byedpi Android assets

`ciadpi` is built from `hufrea/byedpi`.

The built-in strategy list lives only in
`core/backend/compile/byebyeedpi-strategies.list` and is embedded in Go.
Flutter does not bundle or download another copy.

The list was copied from `romanvht/ByeByeDPI` under GPL-3.0, from
`app/src/main/assets/proxytest_strategies.list`.

Strategy source commit: `ee87264e3bab779d3c23e41e11c45d5f8189faec`

Renovate tracks the source repository's `master` branch through this commit.
Its PR updates the reference only: before merging, copy the strategy file from
that exact commit into `core/backend/compile/byebyeedpi-strategies.list` and run
`go test ./backend/compile` from `core`. Keep the source reference and embedded
list together in the same update; do not restore a Flutter asset copy.

The Android build applies both `tool/patches/byedpi-android-ifaddrs.patch` and
`tool/patches/byedpi-socks-auth.patch` before compilation and links libdl. The
SOCKS5 listener can require RFC 1929 username/password authentication from a
private credentials file. The authenticated UDP relay pairs with
`tool/patches/mihomo-socks5-udp-token.patch` to verify each relay packet with
a per-session token exchanged over the authenticated SOCKS5 connection.
On API 21–23, interface-name lookup fails explicitly;
literal IP addresses keep working. On API 24+, getifaddrs/freeifaddrs are resolved
from libc at runtime. Neither symbol is a load-time requirement. The patches and
resulting ABI hashes participate in the asset cache stamp. Updating or reverting
the source pin requires reviewing the patches and
`core/backend/compile/cli_schema.json` together.

Run `bash tool/check_byedpi.sh` in the development shell to compare the policy
with the pinned upstream option table and launch all bundled and fallback
strategies, verifying their local SOCKS handshake. This checks CLI compatibility,
not circumvention effectiveness on a particular provider. Android ABI builds and
real-device network checks remain required before release.
