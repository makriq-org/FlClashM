# 🚀 User Guide

Everything you need to make FlClashM do exactly what you want — from the first connection to fine-tuning routes.

---

## ⏱ Quick start

1. 📥 **Install the app** — download an APK from [GitHub Releases](https://github.com/makriq-org/FlClashM/releases) (which build to pick — see the [README](../../README.md#-download)).
2. ➕ **Add a profile** — via a subscription link, a file, a QR code, or Android TV.
3. 🔌 **Flip the switch** — the app enables VPN/TUN and brings up the needed built-in nodes.

The rest depends on what the profile contains. Below are the three topics most often needed for that.

---

## 📖 Sections

### 🧩 [Built-in nodes](profiles.md)

FlClashM's headline feature: **ByeDPI, OlcRTC, and NaiveProxy launch straight from the YAML profile** and behave like ordinary proxies. One site can go through DPI circumvention, another can be disguised as a video call, and the rest sent directly.

> Start here if you want to understand how to fill in `proxies` for built-in nodes and how the startup check works.

### 🎯 [Split tunneling](split-tunneling.md)

Controlling **which apps use the VPN** and which go directly. Rules can be set manually in settings or right in the profile (where they take priority). Exact package names, wildcards, and regular expressions are supported.

### 🎨 [Provider hints](provider-hints.md)

The provider can send a set of `flclashm-*` hints in the subscription headers — change the theme, background, widget set, show a service name. This is **appearance and convenience**; hints don't affect security or routing.

---

> 🌍 Other languages: [Русский](../../../ru/docs/user-guide/README.md) · [中文](../../../zh/docs/user-guide/README.md) · [فارسی](../../../fa/docs/user-guide/README.md)
