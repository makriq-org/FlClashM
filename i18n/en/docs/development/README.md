# 🛠 Developer Documentation

How FlClashM is built and how to work with it without breaking the cheap upstream sync.

**Core principle:** the fork's product logic lives in `lib/product/**` and is separated from the FlClashX base. Base code reaches it only through registered integration points. This keeps upstream updates cheap and prevents the fork's specifics from dissolving into the base.

---

## 📖 Sections

| Section | About |
|---------|-------|
| 🏗 **[Architecture](architecture.md)** | The main processing pipeline, layers, the base/product boundary, core services |
| ⚙️ **[Runtime](runtime.md)** | Profile processing, built-in node verification and lifecycle, the VPN snapshot |
| 🔒 **[Security](security.md)** | Runtime policy, Android protections, provider-header boundaries |
| 📦 **[Releases](release-contract.md)** | Release contents, pipeline, signed update delivery, rollback |
| 🔄 **[Upstream sync](upstream-sync.md)** | The cheap base-update process |
| ✅ **[Build verification](verification.md)** | Local gates and CI |

---

## 🧰 Local commands (quick)

On NixOS the whole environment is defined by `flake.nix`:

```bash
nix develop -c make dev              # debug APK (arm64)
nix develop -c make check            # boundaries + release-contract + drift + test + analyze
nix develop -c make fetch-upstream   # pull upstream/dev
```

Build and check details — in [build verification](verification.md) and the [project README](../../README.md#-building).

> 🤖 Rules for working on the code (base/product boundaries, touchpoints, drift budget) are in [AGENTS.md](../../../../AGENTS.md).

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/README.md) · [中文](../../../zh/docs/development/README.md) · [فارسی](../../../fa/docs/development/README.md)
