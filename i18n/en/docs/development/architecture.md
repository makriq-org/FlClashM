# 🏗 Architecture

FlClashM is built on top of FlClashX. The fork's product logic is separated from the base so that upstream updates don't break the custom features.

## 🔗 The main pipeline

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| Stage | What it does |
|-------|--------------|
| **RawProfile** | The source profile as-is |
| **ProfileCompiler** | Reads the profile, normalizes split tunneling, compiles built-in nodes |
| **SecurityPolicy** | Forces TUN on Android |
| **RuntimePlan** | Builds the runtime startup plan |
| **EngineManager** | Manages the engine lifecycle |
| **EngineAdapter** | Bridge to `mihomo` |

## 🧱 Layers

1. 🎛 **FlClashX base** — UI, navigation, the base runtime path.
2. 📦 **Product layer** (`lib/product/**`) — profile compilation, security, updates, fork-only pages.
3. ⚙️ **Runtime layer** — `mihomo` (baseline) and the built-in nodes `naiveproxy`, `olcrtc`, `byedpi`.
4. 📱 **Platform layer** — Android VPN, foreground service, installer, notifications.

## 🚧 The base/product boundary

Base code outside `lib/product/**` reaches the product layer **only through integration points** from `tool/product_touchpoints.json`.

- Live `lib/views/**` are **not duplicated** into `lib/product/**`: the base keeps the upstream screens with minimal hooks.
- Widget classes and `Widget` factories in `lib/product/**` are forbidden by default; FlClashM's own elements must be explicitly listed in `allowedProductUi` in `tool/product_touchpoints.json` with a reason.

Enforced by a gate:

```bash
dart tool/check_product_boundaries.dart
```

> 📎 How this relates to upstream updates — in [upstream sync](upstream-sync.md). Rules for contributors — in [AGENTS.md](../../../../AGENTS.md).

## 🧩 Core services

| Service | Responsible for |
|---------|-----------------|
| `ProfileCompiler` | Reading and normalizing the profile |
| `SecurityPolicy` | Forcing TUN on Android |
| `EngineManager` | The engine lifecycle |
| `BuiltInProxySupervisor` | The built-in node lifecycle |
| `AppUpdateService` | Checking, downloading, and installing app updates |
| `AppUpdateManifestVerifier` | Verifying the update manifest signature and contract |
| `AccessControlService` | Split tunneling |

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/architecture.md) · [中文](../../../zh/docs/development/architecture.md) · [فارسی](../../../fa/docs/development/architecture.md)
