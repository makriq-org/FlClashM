# ✅ Проверка сборки

## 🤖 CI-проверка

`.github/workflows/android-base-verification.yaml` проверяет:

- 🚧 границы продуктового слоя;
- 📦 контракт релизов;
- 🔄 расхождения base-файлов с `upstream/dev`;
- 🧪 тесты `test/product` и `test/tool`;
- 🔍 выборочный статический анализ продуктового и выпускного кода;
- 🏗 Android-сборку для `arm64`.

> ➕ При изменении `android`, `core`, `assets/runtimes`, `setup.dart` или `lib/product/runtime` дополнительно собираются `armeabi-v7a` и `x86_64`.

**Как запускается.** Для рабочих веток основной процесс запускается событием pull request, а `push` используется только для `main`. Отдельный процесс непрерывности выпуска оставлен для ручного запуска: автоматически эта проверка уже входит в основной процесс, поэтому один коммит не создаёт дублирующие наборы проверок. Новый запуск того же pull request отменяет предыдущий незавершённый. Если изменена только посторонняя документация, тяжёлые задания пропускаются.

## 💻 Локальная проверка

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
dart tool/check_base_drift.dart
flutter test test/product test/tool
flutter analyze --fatal-infos lib/product test/product test/tool
```

## 📱 Android-сборка

Нужны: Android SDK, NDK `28.0.13004108`, JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```

> ⚠️ Полная проверка запуска приложения, VPN, фоновых служб и встроенных узлов на **реальных Android-устройствах** остаётся локальной.

---

> 🌍 Другие языки: [English](../../../en/docs/development/verification.md) · [中文](../../../zh/docs/development/verification.md) · [فارسی](../../../fa/docs/development/verification.md)
