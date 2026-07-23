# 🔄 Upstream Sync

FlClashM is built on top of FlClashX. The product logic is separated to keep the base update **cheap**.

## 🧭 Principle

- 📦 Product logic lives in `lib/product/**`.
- 🚧 Code outside `lib/product/**` reaches it only through integration points.

> 📎 More on the base/product boundary — in [architecture](architecture.md#-the-baseproduct-boundary).

## 📝 Update process

1. ⬇️ Pull FlClashX into a separate branch (updates are done from `upstream/dev`).
2. 🧩 Resolve conflicts in `lib/product/**`.
3. 🎛 Outside `lib/product/**`, keep mounted screens in the upstream `lib/views/**`; graft product logic in with minimal hooks only.
   - If a base file really imports `lib/product/**` — the entry must be in `tool/product_touchpoints.json`.
   - Any other base drift must be explained in `tool/base_drift_allowlist.json`.
4. ✅ After the merge, run the checks:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
dart tool/check_base_drift.dart
```

> 🤖 The full procedure (fetch, `rerere`, the drift checker, the final gates) is described in the "Upstream update procedure" section of [AGENTS.md](../../../../AGENTS.md).

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/upstream-sync.md) · [中文](../../../zh/docs/development/upstream-sync.md) · [فارسی](../../../fa/docs/development/upstream-sync.md)
