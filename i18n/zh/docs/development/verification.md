# ✅ 构建验证

## 🤖 CI 检查

`.github/workflows/android-base-verification.yaml` 检查：

- 🚧 产品层边界；
- 📦 发布契约；
- 🔄 基线文件相对 `upstream/dev` 的漂移；
- 🧪 `test/product` 与 `test/tool` 测试；
- 🔍 对产品与发布代码的选择性静态分析；
- 🏗 Android `arm64` 构建。

> ➕ 当 `android`、`core`、`assets/runtimes`、`setup.dart` 或 `lib/product/runtime` 变化时，还会构建 `armeabi-v7a` 与 `x86_64`。

**如何触发。** 对工作分支，主工作流在 pull request 事件上运行，而 `push` 只用于 `main`。独立的发布连续性工作流保留供手动运行：该检查其实已自动包含在主工作流中，因此单次提交不会产生重复的检查集。同一 pull request 的新运行会取消上一次未完成的运行。若仅改动无关文档，则跳过重型任务。

## 💻 本地检查

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
dart tool/check_base_drift.dart
flutter test test/product test/tool
flutter analyze --fatal-infos lib/product test/product test/tool
```

## 📱 Android 构建

需要：Android SDK、NDK `28.0.13004108`、JDK 17。

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```

> ⚠️ 在**真实 Android 设备**上对应用启动、VPN、后台服务与内置节点的完整验证仍留在本地。

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/verification.md) · [English](../../../en/docs/development/verification.md) · [فارسی](../../../fa/docs/development/verification.md)
