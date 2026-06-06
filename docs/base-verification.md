# Предварительная проверка

## CI-проверка

Базовый шлюз для `push`/`pull_request`: `.github/workflows/android-base-verification.yaml`

Проверяет:

- `dart tool/check_product_boundaries.dart`
- `dart tool/check_release_continuity.dart`
- `flutter test test/product`
- `flutter analyze --fatal-infos lib/product test/product tool/check_product_boundaries.dart tool/check_release_continuity.dart tool/check_android_release_artifacts.dart tool/write_release_metadata.dart tool/release_contract.dart setup.dart lib/common/constant.dart lib/core_version.dart`
- Android smoke: `dart setup.dart android --arch arm64 --out core` + `flutter build apk --release --target-platform android-arm64`

Почему именно так:

- Анализ намеренно ограничен продуктовым scope, чтобы шлюз оставался строгим,
  но не упирался в legacy info-шум по всему репозиторию.
- Smoke-сборка использует `arm64 release`, потому что это ближе к реальному
  Android-пути, чем `debug`, но заметно дешевле полного тег-релиза с split APK,
  universal APK и AAB.
- Пуш ограничен ветками, чтобы шлюз не дублировал конвейер тег-релизов: GitHub
  не применяет `paths`-фильтр к пушу тегов.
- Подписанный релиз, полная multi-ABI упаковка и публикация остаются в
  `.github/workflows/build.yaml`.
- Проверка SHA-256 сертификата подписи выполняется только в конвейере тег-релизов
  после реальной сборки подписанного APK.

## Локально на NixOS

Минимальная локальная проверка без Android SDK:

```bash
nix shell nixpkgs#flutter nixpkgs#go --command bash -lc '
  flutter pub get &&
  dart tool/check_product_boundaries.dart &&
  dart tool/check_release_continuity.dart &&
  flutter test test/product &&
  flutter analyze --fatal-infos \
    lib/product \
    test/product \
    tool/check_product_boundaries.dart \
    tool/check_release_continuity.dart \
    tool/check_android_release_artifacts.dart \
    tool/write_release_metadata.dart \
    tool/release_contract.dart \
    setup.dart \
    lib/common/constant.dart \
    lib/core_version.dart
'
```

Этого достаточно, чтобы воспроизвести быстрые части шлюза перед пушем.

## Локальная Android smoke-сборка

Нужны:

- `ANDROID_SDK_ROOT` или `ANDROID_HOME`
- Android NDK `28.0.13004108` в `$ANDROID_SDK_ROOT/ndk/28.0.13004108` или явный `ANDROID_NDK`
- Android SDK: platform/build-tools `34`, `35`, `36` и `cmake;3.22.1`
- JDK 17

На NixOS AGP может пытаться запускать скачанный через Maven `aapt2`, который
падает на stub-ld. Для локальной сборки задайте:

```
GRADLE_OPTS=-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_SDK_ROOT/build-tools/34.0.0/aapt2
```

Команда:

```bash
nix shell nixpkgs#flutter nixpkgs#go nixpkgs#jdk17 nixpkgs#android-tools --command bash -lc '
  export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_SDK_ROOT/build-tools/34.0.0/aapt2" &&
  flutter pub get &&
  dart setup.dart android --arch arm64 --out core &&
  core_version=$(sed -n "s/^const String kCoreVersionFromSource = '"'"'\(.*\)'"'"';$/\1/p" lib/core_version.dart) &&
  test -n "$core_version" &&
  flutter build apk \
    --release \
    --target-platform android-arm64 \
    --dart-define=APP_ENV=pre \
    --dart-define=CORE_VERSION="$core_version"
'
```

Если SDK/NDK на машине нет, минимальная локальная проверка заканчивается на
шаге выше без Android SDK, а smoke-сборка выполняется в CI.

## Что этот шлюз не покрывает

- Секреты релизной подписи и публикацию
- Split-APK по каждому ABI
- Universal APK
- App bundle (AAB)
- Полный анализ репозитория без legacy-шума
