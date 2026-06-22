# 上游同步

FlClashM 基于 FlClashX 构建。产品逻辑分离以保持更新成本低。

## 原则

- 产品逻辑位于 `lib/product/**`
- `lib/product/**` 之外的代码只能通过集成点访问

## 更新流程

1. 将 FlClashX 拉取到单独的分支
2. 解决 `lib/product/**` 中的冲突
3. 在 `lib/product/**` 之外，只修改 `tool/product_touchpoints.json` 中的文件
4. 合并后运行检查：

```bash
dart tool/check_product_boundaries.dart
dart tool/check_upstream_drift.dart
dart tool/check_release_continuity.dart
flutter test test/product
```
