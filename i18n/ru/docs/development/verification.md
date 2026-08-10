# ✅ Проверка сборки

## 🤖 CI-проверка

`.github/workflows/android-base-verification.yaml` проверяет:

- 🚧 границы продуктового слоя;
- 📦 контракт релизов;
- 🔄 расхождения base-файлов с `upstream/dev`;
- 🧪 тесты `test/product` и `test/tool`;
- 🔒 закрепление внешних GitHub Actions за полными commit SHA;
- 🔍 выборочный статический анализ продуктового и выпускного кода;
- 🏗 Android-сборку для `arm64`.

> ➕ При изменении Android/runtime-пути дополнительно собирается `armeabi-v7a`, а `x86_64` запускается на Android Emulator.

Эмуляторный E2E устанавливает debug APK, проверяет наличие всех встроенных runtime-бинарников и запускает ByeDPI через боевой AIDL/process-manager путь. Затем он поднимает настоящий TUN и foreground-службу с локальным профилем `DIRECT`, убивает процесс `:remote`, ждёт восстановления binder-сервиса и повторно запускает core и VPN через поддерживаемый headless AIDL-контракт. Системное VPN-разрешение выдаётся через `ACTIVATE_VPN`: это единственная тестовая предпосылка, потому что системный consent UI намеренно не автоматизируется. Внешняя сеть тесту не нужна.

Автоматический `START_STICKY`-перезапуск `FlVpnService` после гибели общего процесса `:remote` в этот E2E не заявляется: Android восстанавливает binder-сервис, а headless recovery выполняется явной production-командой через AIDL.

При падении workflow сохраняет instrumentation output, `logcat`, список процессов и срезы `dumpsys` для служб, VPN-сети и уведомлений. Проверка покрывает Android-контракт на `x86_64`; работоспособность runtime-бинарников на ARM ABI по-прежнему подтверждается перед выпуском на реальном устройстве.

**Как запускается.** Для рабочих веток основной процесс запускается событием pull request, а `push` используется только для `main`. Отдельный процесс непрерывности выпуска оставлен для ручного запуска: автоматически эта проверка уже входит в основной процесс, поэтому один коммит не создаёт дублирующие наборы проверок. Новый запуск того же pull request отменяет предыдущий незавершённый. Если изменена только посторонняя документация, тяжёлые задания пропускаются.

Отдельный `secret-scan` проверяет Gitleaks все коммиты, добавленные pull request или push в `main`. Версия сканера и SHA-256 его архива зафиксированы в workflow.

## 💻 Локальная проверка

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_actions_pinning.dart
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

> ⚠️ Эмуляторный E2E не заменяет предрелизную проверку ARM ABI на реальном Android-устройстве.

---

> 🌍 Другие языки: [English](../../../en/docs/development/verification.md) · [中文](../../../zh/docs/development/verification.md) · [فارسی](../../../fa/docs/development/verification.md)
