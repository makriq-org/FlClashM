# FlClashM

[Russian](README.md)

[![Downloads](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Last Version](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![License](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)

`FlClashM` is an Android client for `mihomo`.

## Features

- VPN/TUN connection through `mihomo`.
- Profiles from links, files, QR codes, and Android TV transfer.
- `rule`, `global`, and `direct` modes, group delay checks, and node selection.
- Built-in local nodes: `naiveproxy`, `olcrtc`, and `byedpi`.
- Dashboard widgets for profile, traffic, IP, mode, node switching, and service info.
- Display customization via provider hints.
- In-app updater with stable and pre-release support.
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
