<div align="center">

<img src="../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="128" height="128">

# FlClashM

**Censorship circumvention on Android — behind a single button.**

[![Downloads](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Latest Version](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![License](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)
[![Based on FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

Android client for `mihomo`, a fork of [FlClashX](https://github.com/pluralplay/FlClashX) that hides complex censorship-circumvention tools behind a single switch.

[Русский](../../README.md) · **English** · [中文](../zh/README.md) · [فارسی](../fa/README.md)

</div>

---

> ⚠️ This project is under active development. Some features are still being refined, and the interface may change.

## 📑 Table of contents

- [Why this client](#-why-this-client)
- [Key advantages](#-key-advantages)
- [Other features](#-other-features)
- [Download](#-download)
- [Documentation](#-documentation)
- [Building](#-building)
- [Acknowledgments](#-acknowledgments)
- [License](#-license)

---

## 🎯 Why this client

There are several powerful circumvention tools, and each lives in its own silo:

- 🛡 **[ByeDPI](https://github.com/hufrea/byedpi)** — DPI circumvention for resources blocked "from the inside" (e.g. YouTube or Discord in some regions).
- 📞 **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — bypasses whitelists by disguising traffic as a WebRTC call of an allowed service such as Yandex Telemost.
- 🌩 **[StormDNS](https://github.com/nullroute1970/StormDNS)** — bypasses whitelists by disguising traffic as ordinary DNS queries to an allowed resolver.
- 🎭 **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — bypasses blocklists by parroting Chrome browser traffic.

Each technology is great for its own job, but there was no single place that brought them all together. I wanted to configure everything in one spot and just press "connect".

So I made **FlClashM**. Its goal is to become that **single button**: the provider prepares the configuration, the user flips the switch, and the connection works on any network.

---

## ✨ Key advantages

### 🧩 Built-in nodes right in the profile

Unlike regular clients, FlClashM can launch **special nodes directly from the YAML profile**. They look like ordinary proxies and take part in routing rules: one site through ByeDPI, another through OlcRTC, and everything else directly.

<table>
<tr><td>

🛡 **ByeDPI** — automatically cycles through DPI-circumvention strategies and caches the working one.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

</td></tr>
<tr><td>

📞 **OlcRTC** — a tunnel over WebRTC disguised as a video call.

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

</td></tr>
<tr><td>

🌩 **StormDNS** — a tunnel inside ordinary DNS queries.

```yaml
proxies:
  - name: "storm"
    type: stormdns
    domains: ["v.example.com"]
    encryption: chacha20
    encryption-key: "<key>"
```

</td></tr>
<tr><td>

🎭 **NaiveProxy** — parroting of Chrome traffic.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

</td></tr>
</table>

📖 [More about built-in nodes →](docs/user-guide/profiles.md)

### 🎯 Split tunneling via profile

The provider can define split-tunneling rules directly in the profile — which apps go through the VPN and which don't. Exact package names, wildcards, and regular expressions are supported; lists can be loaded from files or URLs. The profile takes priority over manual settings.

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

📖 [More about split tunneling →](docs/user-guide/split-tunneling.md)

---

## 🛠 Other features

- 🔌 **VPN/TUN connection** through `mihomo`.
- 📥 **Profiles** from links, files, QR codes, and Android TV.
- 🔀 **Operating modes**: rules, global, direct.
- 🧰 **Widgets** and a **Quick Settings tile** for VPN control.
- ⬆️ **Built-in updates** with signature and checksum verification.
- 🔔 **Notifications** about subscription expiration.
- 🚀 **Auto-start** after device reboot.
- 🎨 **Customization** via [provider hints](docs/user-guide/provider-hints.md).

---

## 📥 Download

Release builds are published in [GitHub Releases](https://github.com/makriq-org/FlClashM/releases).

| File | What it's for |
|------|---------------|
| `FlClashM-android-universal.apk` | Universal build (pick this if unsure) |
| `FlClashM-android-arm64-v8a.apk` | 64-bit ARM (most modern phones) |
| `FlClashM-android-armeabi-v7a.apk` | 32-bit ARM (older devices) |
| `FlClashM-android-x86_64.apk` | x86_64 (emulators, some tablets) |
| `FlClashM-android-release.aab` | Android App Bundle |

> ℹ️ By default the built-in updater shows only stable versions. Pre-releases can be enabled in settings.

---

## 📚 Documentation

Full reference — in the **[documentation hub](docs/README.md)**.

**🚀 For users**
- 🧩 [Built-in nodes](docs/user-guide/profiles.md) — ByeDPI, OlcRTC, StormDNS, NaiveProxy
- 🎯 [Split tunneling](docs/user-guide/split-tunneling.md) — management via profile
- 🎨 [Provider hints](docs/user-guide/provider-hints.md) — customization and behavior

**🛠 For developers**
- 🏗 [Architecture](docs/development/architecture.md) · ⚙️ [Runtime](docs/development/runtime.md) · 🔒 [Security](docs/development/security.md)
- 📦 [Releases](docs/development/release-contract.md) · 🔄 [Upstream sync](docs/development/upstream-sync.md) · ✅ [Build verification](docs/development/verification.md)

---

## 🏗 Building

Requires **Flutter 3.41.x**, **JDK 17**, **Android SDK/NDK**, and **Go 1.26.x**.

### On NixOS (recommended)

All dependencies and their versions are pinned by `flake.nix`. The arm64 debug package builds with a single command:

```bash
nix develop -c make dev
```

Result: `build/app/outputs/flutter-apk/app-debug.apk`.

Other tasks run the same way:

```bash
nix develop -c make fetch-upstream check
nix develop -c make install-dev
nix develop -c make release
nix develop -c make clean
```

> The targets `test`, `analyze`, `boundaries`, `release-contract`, and `drift` are also available.

### Without Nix

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

📖 More in [build verification](docs/development/verification.md).

---

## 🙏 Acknowledgments

FlClashM is built on top of [FlClashX](https://github.com/pluralplay/FlClashX) — an excellent cross-platform client for Clash/Mihomo. Huge thanks to the authors for their work and open-source code, without which this project would not have been possible.

Special thanks to the authors of [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc), [StormDNS](https://github.com/nullroute1970/StormDNS), and [NaiveProxy](https://github.com/klzgrad/naiveproxy) — without their tools, censorship circumvention would not be possible.

---

## 📄 License

The app code is distributed under the **GPL-3.0** license. Third-party cores and bundled executables retain their original licenses.
