# ✅ Build Verification

## 🤖 CI check

`.github/workflows/android-base-verification.yaml` checks:

- 🚧 product-layer boundaries;
- 📦 the release contract;
- 🔄 base-file drift against `upstream/dev`;
- 🧪 the `test/product` and `test/tool` tests;
- 🔍 selective static analysis of the product and release code;
- 🏗 the Android `arm64` build.

> [!NOTE]
> When `android`, `core`, `assets/runtimes`, `setup.dart`, or `lib/product/runtime` change, `armeabi-v7a` and `x86_64` are also built.

**How it's triggered.** For working branches the main workflow runs on the pull request event, while `push` is used only for `main`. A separate release-continuity workflow is kept for manual runs: automatically that check is already part of the main workflow, so a single commit doesn't create duplicate check sets. A new run of the same pull request cancels the previous unfinished one. If only unrelated documentation changed, the heavy jobs are skipped.

## 💻 Local check

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
dart tool/check_base_drift.dart
flutter test test/product test/tool
flutter analyze --fatal-infos lib/product test/product test/tool
```

## 📱 Android build

Requires: Android SDK, NDK `28.0.13004108`, JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```

> [!WARNING]
> Full verification of app startup, VPN, background services, and built-in nodes on **real Android devices** stays local.

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/verification.md) · [中文](../../../zh/docs/development/verification.md) · [فارسی](../../../fa/docs/development/verification.md)
