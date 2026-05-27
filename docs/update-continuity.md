# Update Continuity

## Source Of Truth

- `tool/release_continuity_baseline.json` хранит release continuity contract.
- `pubspec.yaml` остается source of truth для `versionName` и `versionCode`.
- `android/app/build.gradle.kts` остается source of truth для Android `applicationId`.
- `lib/common/constant.dart` остается source of truth для runtime release repository.
- `.github/workflows/build.yaml`, `.github/workflows/continuity.yaml` и `.github/workflows/android-base-verification.yaml` остаются source of truth для CI wiring.

## Что проверяется

Guard: `tool/check_release_continuity.dart`

- `pubspec.yaml`: build suffix из `version` обязан быть строго больше `versionCodeFloor`.
- `android/app/build.gradle.kts`: `applicationId` обязан оставаться `com.makriq.flclash`.
- `android/app/build.gradle.kts`: release signing bridge обязан продолжать читать `keystore.jks`, `keyAlias`, `storePassword`, `keyPassword`.
- `lib/common/constant.dart`: `packageName` обязан совпадать с Android continuity package, `repository` обязан оставаться `makriq-org/FlClashM`.
- `.github/workflows/build.yaml`: должны оставаться ожидаемые release secret names `KEYSTORE`, `KEY_ALIAS`, `STORE_PASSWORD`, `KEY_PASSWORD`, и их wiring в `android/local.properties`.
- `.github/workflows/build.yaml`: должен быть зафиксирован `CONTINUITY_RELEASE_REPOSITORY`.
- `.github/workflows/build.yaml`: release lookup обязан идти через `CONTINUITY_RELEASE_REPOSITORY`, а tag workflow обязан вызывать guard до setup signing и до Android build.
- Только tag-release workflow проверяет `GITHUB_REPOSITORY == makriq-org/FlClashM`, чтобы релиз не ушел в другой канал.
- `.github/workflows/continuity.yaml`: обязан запускать тот же guard без repo pinning, чтобы обычные PR/push и fork-проверки не ломались.

## Где guard запускается

- Локально: `nix shell nixpkgs#flutter --command dart tool/check_release_continuity.dart`
- Локально для release channel guard: `nix shell nixpkgs#flutter --command dart tool/check_release_continuity.dart --github-repository makriq-org/FlClashM`
- CI: `.github/workflows/continuity.yaml` и `.github/workflows/android-base-verification.yaml`
- Tag release pipeline: ранний шаг `Check release continuity` в `.github/workflows/build.yaml`

## Как обновлять floor

После следующего публичного continuity milestone:

1. Зафиксировать фактический опубликованный `versionCode`.
2. Обновить `versionCodeFloor` в `tool/release_continuity_baseline.json`.
3. Обновить provenance-поля в `continuityBaseline`:
   - `sourceTag`
   - `publishedAt`
   - `sourcePubspecVersion`
4. Поднять `pubspec.yaml` на версию с build suffix строго выше нового floor.
5. Прогнать `dart tool/check_release_continuity.dart` и дождаться зеленого CI.

## Почему baseline локальный

- Нет сетевой зависимости на старый репозиторий в каждом билде.
- Инвариант формализован и ревьюится как обычный change в git.
- Обновление baseline остается дешевым и обратимым.
