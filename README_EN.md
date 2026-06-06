# FlClashM

[Russian](README.md)

[![Downloads](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Last Version](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![License](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)

`FlClashM` is an Android client for `mihomo`.

## Exclusive Features

### Built-in nodes

Three node types are declared directly in the profile and participate in regular proxy groups and rules — no separate apps, no manual port setup.

**NaiveProxy** (`type: naiveproxy`) — the app runs the bundled naiveproxy binary, writes a config, and substitutes a local SOCKS5 listener for the node. The profile only needs `name` and `proxy`.

**ByeDPI** (`type: byedpi`) — bundled ciadpi with DPI circumvention. `mode: manual` accepts a raw ciadpi argument string; `mode: auto` cycles through strategies from the ByeByeDPI set, caches the working one, and applies it on cold start. `{sni}` substitution is supported.

**OlcRTC** (`type: olcrtc`) — bundled olcrtc in CNC mode. The app manages the listener and config; the profile only specifies `name` and the server connection parameters.

### Profile-driven split tunneling

Split tunneling is configured in the profile via `profileAccessControl`. The compilation pipeline normalizes the rules before passing them to mihomo — no manual VPN exclusions needed.

### In-app updater

The app checks for updates on its own and offers to install them from the UI. Stable releases are shown by default; pre-releases can be enabled in settings.

## Other features

- VPN/TUN connection through `mihomo`.
- Profiles from links, files, QR codes, and Android TV transfer.
- `rule`, `global`, and `direct` modes, group delay checks, and node selection.
- Dashboard widgets for profile, traffic, IP, mode, node switching, and service info.
- Display customization via provider hints.
- Android foreground notification and Quick Settings tile.

## Download

Release builds are published in
[GitHub Releases](https://github.com/makriq-org/FlClashM/releases).

Android artifacts:

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

By default, the in-app updater shows stable releases only. Pre-releases must be
enabled explicitly in settings.

## Build

You need Flutter 3.41.x, JDK 17, Android SDK/NDK, and Go 1.26.x.
On NixOS, run the commands from a clean shell containing those packages.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

Signed public releases are built by GitHub Actions and require
`KEYSTORE`, `KEY_ALIAS`, `STORE_PASSWORD`, and `KEY_PASSWORD`.
The full release process is described in [docs/release-contract.md](docs/release-contract.md).

## Provider Hints

Subscriptions may send `flclashm-*` headers for display and convenience:

- `flclashm-widgets` — dashboard widget order.
- `flclashm-view` — proxy page layout.
- `flclashm-custom` — when display hints are applied: add or update.
- `flclashm-denywidgets` — dashboard editing lock.
- `flclashm-servicename`, `flclashm-servicelogo`, `flclashm-serverinfo` — service info.
- `flclashm-background`, `flclashm-hex` — appearance.
- `flclashm-settings` — autostart and update-check hints.
- `flclashm-globalmode` — mode-selector visibility.

Full contract: [docs/product-customization.md](docs/product-customization.md).
Security policy: [docs/security-policy.md](docs/security-policy.md).

## Documentation

- [Architecture](docs/architecture.md)
- [Runtime and built-in nodes](docs/runtime.md)
- [ByeDPI](docs/byedpi.md)
- [Security policy](docs/security-policy.md)
- [Release contract](docs/release-contract.md)
- [Upstream maintenance](docs/upstream-maintenance.md)
- [Compatibility boundaries](docs/compatibility-boundaries.md)

## License

The app code is licensed under GPL-3.0. Third-party cores and bundled binaries
keep their own licenses; see `assets/runtimes/**/README.md` and the related
documents under `docs/`.
