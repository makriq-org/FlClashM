# Architecture

FlClashM is built on top of FlClashX. Product logic is separated from the base so that updates don't break custom features.

## Main pipeline

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| Stage | Description |
|-------|-------------|
| **RawProfile** | Raw profile |
| **ProfileCompiler** | Reads the profile, normalizes split tunneling |
| **SecurityPolicy** | Applies Android security rules |
| **RuntimePlan** | Builds the runtime launch plan |
| **EngineManager** | Manages the engine lifecycle |
| **EngineAdapter** | Bridge to `mihomo` |

## Layers

1. **FlClashX Base** — UI, navigation, base runtime path.
2. **Product layer** (`lib/product/**`) — profile compilation, security, updates.
3. **Runtime layer** — `mihomo`, built-in nodes.
4. **Platform layer** — Android VPN, service, notifications.

## Base-product boundary

Base code outside `lib/product/**` accesses the product layer only through integration points from `tool/product_touchpoints.json`.

```bash
dart tool/check_product_boundaries.dart
```

## Core services

| Service | Responsible for |
|---------|-----------------|
| `ProfileCompiler` | Reading and normalizing the profile |
| `SecurityPolicy` | Mandatory security rules |
| `EngineManager` | Engine lifecycle |
| `AppUpdateService` | Checking and installing updates |
| `AccessControlService` | Split tunneling |
