# Build verification

## CI check

`.github/workflows/android-base-verification.yaml` verifies:

- product layer boundaries;
- release contract;
- `test/product` tests;
- Android smoke build.

## Local check

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_upstream_drift.dart
dart tool/check_release_continuity.dart
flutter test test/product
flutter analyze --fatal-infos lib/product test/product
```

## Android build

Required: Android SDK, NDK `28.0.13004108`, JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```
