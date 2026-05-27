# Base Verification

## Минимальный stabilization gate

Базовый gate для `push`/`pull_request`: `.github/workflows/android-base-verification.yaml`

Он проверяет:

- `dart tool/check_release_continuity.dart`
- `flutter test test/product`
- `flutter analyze --fatal-infos lib/product test/product tool/check_release_continuity.dart setup.dart lib/common/constant.dart lib/core_version.dart`
- Android smoke: `dart setup.dart android --arch arm64 --out core` + `flutter build apk --release --target-platform android-arm64`

Почему именно так:

- analyze намеренно ограничен product/tooling scope, чтобы gate оставался строгим, но не упирался в legacy info-шум по всему репо.
- smoke собирает `arm64` в `release`, потому что это ближе к реальному Android path, чем `debug`, но заметно дешевле полного tag-release с split APK, universal APK и AAB.
- `push` ограничен branch pushes, чтобы gate не дублировал tag-release pipeline: GitHub не применяет `paths`-фильтр к tag push.
- signed release, full multi-ABI packaging и release upload остаются в `.github/workflows/build.yaml`.

## Локально на свежей NixOS

Минимальный локальный preflight без Android SDK:

```bash
nix shell nixpkgs#flutter nixpkgs#go --command bash -lc '
  flutter pub get &&
  dart tool/check_release_continuity.dart &&
  flutter test test/product &&
  flutter analyze --fatal-infos \
    lib/product \
    test/product \
    tool/check_release_continuity.dart \
    setup.dart \
    lib/common/constant.dart \
    lib/core_version.dart
'
```

Этого достаточно, чтобы перед `push` воспроизвести быстрые gate-части на чистой машине.

## Локальный Android smoke

Нужны:

- `ANDROID_SDK_ROOT` или `ANDROID_HOME`
- Android NDK `28.0.13004108` в `$ANDROID_SDK_ROOT/ndk/28.0.13004108` или явный `ANDROID_NDK`
- JDK 17

Команда:

```bash
nix shell nixpkgs#flutter nixpkgs#go nixpkgs#jdk17 nixpkgs#android-tools --command bash -lc '
  flutter pub get &&
  dart setup.dart android --arch arm64 --out core &&
  core_version=$(sed -n "s/^const String kCoreVersionFromSource = '\''\\(.*\\)'\'';$/\\1/p" lib/core_version.dart) &&
  test -n "$core_version" &&
  flutter build apk \
    --release \
    --target-platform android-arm64 \
    --dart-define=APP_ENV=pre \
    --dart-define=CORE_VERSION="$core_version"
'
```

Если SDK/NDK на машине еще нет, минимальный локальный путь заканчивается на preflight выше, а Android smoke должен пройти в CI.

## Что этот gate не покрывает

- release signing secrets и публикацию
- split-per-ABI release APK
- universal release APK
- `appbundle`
- полный repo-wide analyze без legacy noise cleanup
