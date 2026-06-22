# 构建验证

## CI 检查

`.github/workflows/android-base-verification.yaml` 验证：

- 产品层边界；
- 发布契约；
- `test/product` 测试；
- Android 冒烟构建。

## 本地检查

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_upstream_drift.dart
dart tool/check_release_continuity.dart
flutter test test/product
flutter analyze --fatal-infos lib/product test/product
```

## Android 构建

需要：Android SDK、NDK `28.0.13004108`、JDK 17。

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```
