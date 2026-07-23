# 📚 FlClashM Documentation

Welcome to the reference for **FlClashM** — an Android client for `mihomo` that hides several censorship-circumvention tools behind a single button.

The docs are split in two: a **user guide** — if you're setting up a profile and want things to just work, and a **developer section** — if you build the app, sync the fork, or dig into how it's put together.

> 🌍 Languages: [Русский](../../ru/docs/README.md) (canonical) · **English** · [中文](../../zh/docs/README.md) · [فارسی](../../fa/docs/README.md)
>
> The Russian version is updated first. Translations may lag slightly — when in doubt, follow the Russian text.

---

## 🚀 User guide

How to make the app do what you need.

| Section | About |
|---------|-------|
| 🧩 **[Built-in nodes](user-guide/profiles.md)** | ByeDPI, OlcRTC, and NaiveProxy right in the YAML profile |
| 🎯 **[Split tunneling](user-guide/split-tunneling.md)** | Which apps go through the VPN and which bypass it |
| 🎨 **[Provider hints](user-guide/provider-hints.md)** | `flclashm-*` headers for appearance and behavior |

👉 Not sure where to start — see the **[user guide overview](user-guide/README.md)**.

---

## 🛠 For developers

How the fork is built and how to work with it.

| Section | About |
|---------|-------|
| 🏗 **[Architecture](development/architecture.md)** | Layers, the base/product boundary, core services |
| ⚙️ **[Runtime](development/runtime.md)** | Profile processing and the built-in node lifecycle |
| 🔒 **[Security](development/security.md)** | What the fork guarantees and what the provider can't change |
| 📦 **[Releases](development/release-contract.md)** | Release contents, signing, update delivery, rollback |
| 🔄 **[Upstream sync](development/upstream-sync.md)** | How to cheaply update the upstream base |
| ✅ **[Build verification](development/verification.md)** | Local gates and CI |

👉 The overall map — in the **[developer overview](development/README.md)**.

---

## 🧭 Where else to look

- 📄 **[Project README](../README.md)** — what this is, why, and how to download it.
- 📝 **[CHANGELOG](../../../CHANGELOG.md)** — change history by version.
- 🤖 **[AGENTS.md](../../../AGENTS.md)** — rules for working on the code (for contributors and agents).
