# بررسی بیلد

## بررسی CI

`.github/workflows/android-base-verification.yaml` موارد زیر را بررسی می‌کند:

- مرزهای لایه محصول؛
- قرارداد انتشار؛
- تست‌های `test/product`؛
- بیلد آزمایشی Android.

## بررسی محلی

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
flutter analyze --fatal-infos lib/product test/product
```

## بیلد Android

نیازمند: Android SDK، NDK `28.0.13004108`، JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```
