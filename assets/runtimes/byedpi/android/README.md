# byedpi Android assets

`ciadpi` is built from `hufrea/byedpi`.

The built-in strategy list lives only in
`core/backend/compile/byebyeedpi-strategies.list` and is embedded in Go.
Flutter does not bundle or download another copy.

The list was copied from `romanvht/ByeByeDPI` under GPL-3.0, from
`app/src/main/assets/proxytest_strategies.list`.

Strategy source commit: `96a3c1ff555043d915af814aa4f0e9a572c89aba`

Renovate tracks the source repository's `master` branch through this commit.
Its PR updates the reference only: before merging, copy the strategy file from
that exact commit into `core/backend/compile/byebyeedpi-strategies.list` and run
`go test ./backend/compile` from `core`. Keep the source reference and embedded
list together in the same update; do not restore a Flutter asset copy.
