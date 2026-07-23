# Проверка изменений

## Быстрый выбор набора

| Изменение | Минимальная проверка |
| --- | --- |
| Только Markdown и issue templates | локальные ссылки, внешний link check, формат diff |
| `lib/product/**`, `test/**`, `tool/**` | `make check` |
| Android, core или runtime assets | `make check`, arm64 APK и затронутые ABI |
| Релизный контракт или workflow | `make check` и профильные tool-тесты/команды с параметрами тега |

Документационный PR не требует сборки APK, если он не меняет исполняемый
контракт. При этом команды границ и release continuity остаются дешёвой защитой
от случайных несвязанных изменений.

## Полный локальный набор

На NixOS:

```bash
nix develop -c make check
```

`make check` последовательно запускает:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
dart tool/check_base_drift.dart
flutter test test/product test/tool
flutter analyze --fatal-infos lib/product test/product test/tool \
  tool/check_product_boundaries.dart tool/check_release_continuity.dart \
  tool/check_android_release_artifacts.dart \
  tool/check_android_release_signing.dart tool/write_release_metadata.dart \
  tool/write_app_update_manifest.dart tool/release_contract.dart setup.dart \
  lib/common/constant.dart lib/core_version.dart
```

Вне Nix нужны совместимые Flutter 3.41.x, Go 1.26.x, JDK 17, Android SDK и
NDK `28.0.13004108`. Сначала выполните `flutter pub get`.

## Android smoke build

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release --target-platform android-arm64
```

Для изменений `android`, `core`, `assets/runtimes`, `setup.dart` или
`lib/product/runtime` CI также собирает `armeabi-v7a` и `x86_64`. Локально
проверяйте эти ABI, если изменение зависит от binary packaging, JNI/FFI или
размещения runtime-файлов.

## Что делает CI

`.github/workflows/android-base-verification.yaml` на pull request:

- определяет область по изменённым путям;
- проверяет product boundaries, release continuity и base drift;
- запускает `test/product`, `test/tool` и targeted analyze;
- собирает arm64 release smoke APK для исполняемых изменений;
- включает дополнительные ABI для runtime/platform области.

Если изменена только документация или issue templates, тяжёлые jobs пропускаются
по path detection. Workflow выпуска `.github/workflows/build.yaml` запускается
только тегом `v*` и повторяет гейты перед подписанной сборкой.

## Проверка на устройстве

Автоматические тесты не доказывают работу Android lifecycle. Перед релизом на
реальном устройстве проверяются:

- первое подключение и повторный запуск VPN;
- foreground service, уведомление, tile и widget;
- always-on/cold-start после перезапуска процесса и устройства;
- split tunneling с фактически применённым списком пакетов;
- каждый изменённый встроенный узел на поддерживаемых ABI;
- загрузка обновления и переход в системный установщик.
