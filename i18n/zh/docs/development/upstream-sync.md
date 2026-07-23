# 🔄 上游同步

FlClashM 构建于 FlClashX 之上。产品逻辑被分离，以让基线更新保持**低成本**。

## 🧭 原则

- 📦 产品逻辑位于 `lib/product/**`。
- 🚧 `lib/product/**` 之外的代码只通过集成点访问它。

> 📎 关于 base/product 边界的更多内容见[架构](architecture.md#-baseproduct-边界)。

## 📝 更新流程

1. ⬇️ 在独立分支拉取 FlClashX（更新从 `upstream/dev` 进行）。
2. 🧩 解决 `lib/product/**` 中的冲突。
3. 🎛 在 `lib/product/**` 之外，让挂载的屏幕保留在上游 `lib/views/**`；仅以最小钩子嵌入产品逻辑。
   - 若某基线文件确实导入 `lib/product/**` —— 该条目必须在 `tool/product_touchpoints.json`。
   - 其他任何基线漂移都须在 `tool/base_drift_allowlist.json` 中说明。
4. ✅ 合并后运行检查：

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
dart tool/check_base_drift.dart
```

> 🤖 完整流程（fetch、`rerere`、漂移检查器、最终门禁）见 [AGENTS.md](../../../../AGENTS.md) 中的「上游更新流程」一节。

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/upstream-sync.md) · [English](../../../en/docs/development/upstream-sync.md) · [فارسی](../../../fa/docs/development/upstream-sync.md)
