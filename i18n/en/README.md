<div align="center">

<img src="../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="112" height="112">

# FlClashM

**Android VPN and censorship circumvention in one app.**

[![Release](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases) [![GPL-3.0](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)

[Русский](../../README.md) · **English** · [中文](../zh/README.md) · [فارسی](../fa/README.md)

</div>

A mihomo client based on [FlClashX](https://github.com/pluralplay/FlClashX). Runs ByeDPI, OlcRTC, StormDNS and NaiveProxy from profiles, with subscriptions, split tunneling, a VPN tile and verified APK updates.

> [!NOTE]
> The project is under active development; some features are still being refined.

## 📥 Download

Download an APK from [GitHub Releases](https://github.com/makriq-org/FlClashM/releases). Choose universal if you do not know your device architecture.

| File | Device |
|---|---|
| `FlClashM-android-universal.apk` | Any supported architecture |
| `FlClashM-android-arm64-v8a.apk` | Most current phones |
| `FlClashM-android-armeabi-v7a.apk` | 32-bit ARM devices |
| `FlClashM-android-x86_64.apk` | Emulators and x86_64 devices |
| `FlClashM-android-release.aab` | Android App Bundle |

The app verifies the update manifest signature and APK SHA-256. Prereleases appear in updates after enabling the corresponding setting.

## 🚀 Connect

1. Install the APK and add a subscription by URL, file or QR code.
2. Select a profile and connect. Allow VPN creation on the first run.
3. Use profile rules, global proxy selection or a direct connection.

## 📚 Two guides

| Guide | Contents |
|---|---|
| [🧩 Profile setup](docs/profiles.md) | Node examples, VPN app rules, subscription headers |
| [🛠 Build and maintenance](docs/maintenance.md) | Commands, architecture, security, diagnostics and releases |

## 💬 Report a problem

Open an [issue](https://github.com/makriq-org/FlClashM/issues) with the app version, Android/ABI, steps and expected result. Export a diagnostic ZIP from the logs screen. Do not publish subscriptions, keys or passwords.

## 🙏 Credits and license

Thanks to the authors of [FlClashX](https://github.com/pluralplay/FlClashX), [mihomo](https://github.com/MetaCubeX/mihomo), [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc), [StormDNS](https://github.com/nullroute1970/StormDNS), [NaiveProxy](https://github.com/klzgrad/naiveproxy).

The app is [GPL-3.0](../../LICENSE). Third-party cores and binaries retain their own licenses. Release history: [CHANGELOG](../../CHANGELOG.md).
