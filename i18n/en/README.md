# FlClashM

[![Downloads](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Latest Version](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![License](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)
[![Based on FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

> Android client for `mihomo`, a fork of [FlClashX](https://github.com/pluralplay/FlClashX), that hides complex censorship circumvention tools behind a single button.

[Русская версия](../../README.md) | [中文版](../zh/README.md) | [نسخه فارسی](../fa/README.md)

---

## Why this client

There are several powerful tools for bypassing censorship, but each lives in its own silo:

- **[ByeDPI](https://github.com/hufrea/byedpi)** — DPI circumvention through packet manipulation.
- **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — encrypted tunnel over WebRTC disguised as a video call.
- **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — traffic parroting via Chromium's network stack.

I was tired of assembling a working solution from dozens of different apps: one client for VPN, another for DPI circumvention, a third for traffic masking. None of them allowed configuring everything in one place and just pressing "connect".

So I made **FlClashM**. Its goal is to become that **single button**: the provider prepares the configuration, the user flips the switch, and the connection works in any network.

> ⚠️ This project is under active development. Some features are still being refined, and the interface may change.

---

## Key advantages

### Built-in nodes directly in the profile

Unlike regular clients, FlClashM can launch **special nodes directly from the YAML profile**. They look like regular proxies and participate in routing rules: one site can be routed through ByeDPI, another through OlcRTC, and everything else directly.

**[ByeDPI](https://github.com/hufrea/byedpi)** — DPI circumvention through packet manipulation. FlClashM automatically cycles through strategies from the ByeByeDPI list and caches the working one. UDP is enabled by default and can be disabled per node with `udp: false`.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-test:
      urls:
        - "https://example.com/"
```

**[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — encrypted TCP-over-WebRTC tunnel disguised as a video call through Jitsi Meet or Yandex Telemost. Passes through provider whitelists.

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    auth:
      provider: jitsi
    room:
      id: "https://meet.example.org/room"
    crypto:
      key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    net:
      transport: datachannel
      dns: "1.1.1.1:53"
```

**[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — traffic parroting via Chromium's network stack. Resistant to TLS fingerprinting and active probing.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

[More about built-in nodes](docs/user-guide/profiles.md)

### Split tunneling via profile

The provider can specify which apps should use VPN directly in the profile. Supports exact package names, wildcards, and regular expressions.

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
  exclude-package:
    - '*.yandex.*'
    - '!ru.yandex.browser'
```

Lists can be loaded from files or URLs. Profile settings take priority over manual settings.

[More about split tunneling](docs/user-guide/split-tunneling.md)

---

## Other features

- **VPN/TUN connection** through `mihomo`.
- **Profiles** from links, files, QR codes, and Android TV.
- **Operating modes**: rules, global, direct.
- **Widgets** and **Quick Settings tile** for VPN control.
- **Built-in updates** with checksum verification.
- **Notifications** about subscription expiration.
- **Auto-start** after device reboot.
- **Customization** via provider hints.

---

## Download

Release builds are published in [GitHub Releases](https://github.com/makriq-org/FlClashM/releases).

| File | Description |
|------|-------------|
| `FlClashM-android-universal.apk` | Universal build |
| `FlClashM-android-arm64-v8a.apk` | 64-bit ARM |
| `FlClashM-android-armeabi-v7a.apk` | 32-bit ARM |
| `FlClashM-android-x86_64.apk` | x86_64 |
| `FlClashM-android-release.aab` | Android App Bundle |

By default, the built-in updater shows only stable versions. Pre-releases can be enabled in settings.

---

## Documentation

### For users
- **[Built-in nodes](docs/user-guide/profiles.md)** — ByeDPI, OlcRTC, NaiveProxy
- **[Split tunneling](docs/user-guide/split-tunneling.md)** — management via profile
- **[Provider hints](docs/user-guide/provider-hints.md)** — customization and behavior

### For developers
- **[Architecture](docs/development/architecture.md)** — layers and services
- **[Runtime](docs/development/runtime.md)** — profile processing and built-in nodes
- **[Security](docs/development/security.md)** — security policy
- **[Releases](docs/development/release-contract.md)** — version publishing and rollback
- **[Upstream sync](docs/development/upstream-sync.md)** — base updates
- **[Build verification](docs/development/verification.md)** — local and CI checks

---

## Building

Requires Flutter 3.41.x, JDK 17, Android SDK/NDK, and Go 1.26.x.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

---

## Acknowledgments

FlClashM is built on top of [FlClashX](https://github.com/pluralplay/FlClashX) — an excellent cross-platform client for Clash/Mihomo. Huge thanks to the authors for their work and open-source code, without which this project would not have been possible.

Special thanks to the authors of [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc), and [NaiveProxy](https://github.com/klzgrad/naiveproxy) — without their tools, censorship circumvention would not be possible.

---

## License

The app code is distributed under the GPL-3.0 license. Third-party cores and bundled executables retain their original licenses.
