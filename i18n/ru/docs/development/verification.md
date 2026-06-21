# Проверка сборки

## CI-проверка

`.github/workflows/android-base-verification.yaml` проверяет:

- границы продуктового слоя;
- контракт релизов;
- тесты `test/product`;
- Android smoke-сборку.

## Локальная проверка

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
flutter analyze --fatal-infos lib/product test/product
```

## Android-сборка

Нужны: Android SDK, NDK `28.0.13004108`, JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```
