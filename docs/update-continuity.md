# Update Continuity

## Source Of Truth

- `tool/release_continuity_baseline.json` хранит release continuity contract:
  - Android continuity package
  - release repository
  - release secret names
  - expected continuity signer DN/SHA-256
  - expected Android release artifacts
  - release metadata filename
  - `versionCodeFloor` и provenance последнего публичного continuity release, зафиксированного как floor
- `pubspec.yaml` остается source of truth для `versionName` и `versionCode`.
- `android/app/build.gradle.kts` остается source of truth для Android `applicationId`.
- `lib/common/constant.dart` остается source of truth для runtime release repository.
- `setup.dart` остается source of truth для Android artifact naming.
- `.github/release_template.md` и `.github/pre_release_template.md` остаются source of truth для release page artifact links.
- `.github/workflows/build.yaml`, `.github/workflows/continuity.yaml` и `.github/workflows/android-base-verification.yaml` остаются source of truth для CI wiring.

## Что проверяется

Guard: `tool/check_release_continuity.dart`

- `pubspec.yaml`: build suffix из `version` обязан быть строго больше `versionCodeFloor`.
- Guard локально не читает live GitHub release history и поэтому доказывает только инвариант относительно baseline floor из git.
- `pubspec.yaml` + tag release: stable tag обязан быть `v<versionName>`, pre-release tag обязан начинаться с `v<versionName>-`.
- `android/app/build.gradle.kts`: `applicationId` обязан оставаться `com.makriq.flclash`.
- Android common/app runtime IPC не должен хардкодить legacy source package как installed package:
  explicit intents, internal broadcast `setPackage(...)` и `${applicationId}.permission.RECEIVE_BROADCASTS` должны вычисляться от runtime `applicationId`, а не от `com.follow.clashx`.
- текущий brand contract и остаточные технические compatibility boundaries перечислены в `docs/branding.md` и `docs/compatibility-boundaries.md`.
- `android/app/build.gradle.kts`: release signing bridge обязан продолжать читать `keystore.jks`, `keyAlias`, `storePassword`, `keyPassword` и корректно принимать continuity keystore как в `JKS`, так и в `PKCS12`.
- `lib/common/constant.dart`: `packageName` обязан совпадать с Android continuity package, `repository` обязан оставаться `makriq-org/FlClashM`.
- `setup.dart`: expected Android release artifact names обязаны оставаться в release path.
- `.github/release_template.md` и `.github/pre_release_template.md`: release page обязана продолжать ссылаться на все Android artifacts и metadata asset.
- `.github/workflows/build.yaml`: должны оставаться ожидаемые release secret names `KEYSTORE`, `KEY_ALIAS`, `STORE_PASSWORD`, `KEY_PASSWORD`, и их wiring в `android/local.properties`.
- `.github/workflows/build.yaml`: tag-release workflow не должен публиковать артефакты без полного набора release secrets.
- `.github/workflows/build.yaml`: post-build signer check обязан подтверждать тот же continuity signer SHA-256, что у последнего публичного `FlClash-my`.
- `.github/workflows/build.yaml`: должен быть зафиксирован `CONTINUITY_RELEASE_REPOSITORY`.
- `.github/workflows/build.yaml`: release lookup обязан идти через `CONTINUITY_RELEASE_REPOSITORY`, а tag workflow обязан вызывать guard до setup signing и до Android build.
- `.github/workflows/build.yaml`: tag workflow обязан генерировать `FlClashM-android-release-metadata.json` и прогонять post-build artifact guard.
- Только tag-release workflow проверяет `GITHUB_REPOSITORY == makriq-org/FlClashM`, чтобы релиз не ушел в другой канал.
- `.github/workflows/continuity.yaml`: обязан запускать тот же guard без repo pinning, чтобы обычные PR/push и fork-проверки не ломались.

Artifact guard: `tool/check_android_release_artifacts.dart`

- `dist/`: обязаны существовать все expected Android release artifacts и `FlClashM-android-release-metadata.json`.
- stable `dist/`: для каждого release asset обязан существовать sibling `.sha256`, совпадающий с фактическим файлом.
- metadata JSON обязан совпадать с текущим `pubspec.yaml`, `lib/core_version.dart`, release repository и continuity baseline.

## Где guard запускается

- Локально: `nix shell nixpkgs#flutter --command dart tool/check_release_continuity.dart`
- Локально для stable tag guard: `nix shell nixpkgs#flutter --command dart tool/check_release_continuity.dart --github-repository makriq-org/FlClashM --github-ref-name v0.10.0`
- Локально для pre-release tag guard: `nix shell nixpkgs#flutter --command dart tool/check_release_continuity.dart --github-repository makriq-org/FlClashM --github-ref-name v0.10.0-rc.1`
- CI: `.github/workflows/continuity.yaml` и `.github/workflows/android-base-verification.yaml`
- Tag release pipeline: ранний шаг `Check release continuity` в `.github/workflows/build.yaml`
- Post-build signer continuity check: шаг `Assert Android release signing continuity` в `.github/workflows/build.yaml`
- Post-build artifact guard: шаг `Assert Android release artifacts` в `.github/workflows/build.yaml`

## Как обновлять floor

После каждого публичного continuity release:

1. Зафиксировать фактический опубликованный `versionCode`.
2. Обновить `versionCodeFloor` в `tool/release_continuity_baseline.json`.
3. Обновить provenance-поля в `continuityBaseline`:
   - `sourceTag`
   - `publishedAt`
   - `sourcePubspecVersion`
4. Поднять `pubspec.yaml` на версию с build suffix строго выше нового floor.
5. Прогнать `dart tool/check_release_continuity.dart` и дождаться зеленого CI.

## Почему baseline локальный

- Нет сетевой зависимости на live GitHub release history в каждом билде.
- Инвариант формализован и ревьюится как обычный change в git.
- Обновление baseline остается дешевым и обратимым.
