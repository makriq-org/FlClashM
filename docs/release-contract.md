# Android Release Contract

## Scope

Этот документ фиксирует release contract для Android path в `FlClashM`, чтобы continuity, update и rollback не зависели от ручного знания.

## Source Of Truth

- `tool/release_continuity_baseline.json`
  - continuity package: `com.makriq.flclash`
  - continuity release channel: `makriq-org/FlClashM`
  - expected release secret names
  - expected continuity signer fingerprint
  - expected Android release artifacts
  - release metadata filename
  - `versionCodeFloor` и provenance последнего публичного continuity release
  - начальный baseline импортирован из `FlClash-my`
- `pubspec.yaml`
  - `versionName`
  - `versionCode`
- `setup.dart`
  - Android artifact naming
  - multi-ABI/universal/AAB packaging path
- `android/app/build.gradle.kts`
  - release signing bridge
  - Android `applicationId`
- `.github/workflows/build.yaml`
  - tag release pipeline
  - metadata/checksum/artifact guards

## Release Rules

- Stable tag обязан быть ровно `v<versionName>`.
- Pre-release tag обязан начинаться с `v<versionName>-`.
- `versionCode` обязан быть строго выше `versionCodeFloor`.
- После каждого публичного continuity release нужно обновлять `versionCodeFloor` на фактически опубликованный `versionCode`.
  - Причина: текущий local/tag guard не ходит в GitHub за live `versionCode` history и опирается на baseline из git.
- Stable hotfix/rollback release обязан двигать вперед и `versionName`, и `versionCode`.
  - Причина: Android install/update path требует больший `versionCode`.
  - Причина: in-app updater сравнивает stable releases по Git tag version against installed `versionName`.
- `applicationId` обязан оставаться `com.makriq.flclash`.
- Release signing обязан использовать те же continuity secrets, что и `FlClash-my`:
  - `KEYSTORE`
  - `KEY_ALIAS`
  - `STORE_PASSWORD`
  - `KEY_PASSWORD`
- Release signing bridge обязан принимать continuity keystore как в `JKS`, так и в `PKCS12`, без смены набора secrets.
- Итоговый опубликованный APK обязан иметь тот же signer SHA-256, что и последний публичный continuity release `FlClash-my`.
- Stable release обязан публиковаться только в `makriq-org/FlClashM`.

## Release Payload

Каждый tag release обязан содержать:

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`
- `FlClashM-android-release-metadata.json`

Stable release дополнительно обязан содержать `.sha256` sidecar для каждого файла выше.

`FlClashM-android-release-metadata.json` фиксирует:

- tag
- repository
- release channel
- `versionName`
- `versionCode`
- embedded `coreVersion`
- continuity baseline provenance
- expected Android artifacts

## Pipeline

Tag release workflow: `.github/workflows/build.yaml`

1. `Check release continuity`
   - проверяет continuity package/repository/signing wiring
   - проверяет tag contract against `pubspec.yaml`
2. `Build Android release artifacts`
   - собирает split APKs, universal APK и AAB через `setup.dart`
3. `Assert Android release signing continuity`
   - проверяет, что arm64 release APK подписан тем же continuity-сертификатом
4. `Generate release metadata`
   - пишет machine-readable provenance в `dist/FlClashM-android-release-metadata.json`
5. `Generate sha256`
   - только для stable release
6. `Assert Android release artifacts`
   - проверяет expected files
   - для stable проверяет, что `.sha256` совпадает с фактическими файлами
   - проверяет, что metadata JSON совпадает с source of truth
7. Release upload
   - stable: GitHub Release
   - pre-release: GitHub pre-release

## Update Path

- Android app update path читает только `https://api.github.com/repos/makriq-org/FlClashM/releases/latest`.
- In-app updater работает только для stable app env.
- Candidate release определяется по stable tag version, а не по `versionCode`.
- APK выбирается по ABI; если ABI-specific asset отсутствует, используется universal APK.
- Install path обязан пройти SHA256 verification:
  - сначала по inline `digest`, если GitHub его отдает
  - иначе по sibling `.sha256` asset

Следствие: stable release без корректных checksum sidecars не считается валидным update source.

## Rollback Contract

Rollback не означает повторную публикацию старого APK и не означает reuse старого tag.

Если bad stable release уже опубликован:

1. выбрать last-known-good commit или hotfix commit
2. поднять `pubspec.yaml` на новый `versionName`
3. поднять `versionCode` выше уже опубликованного bad release
4. выпустить новый stable tag по правилу `v<versionName>`
5. не менять continuity secrets, `applicationId` и release repository

Чего делать нельзя:

- переиспользовать уже опубликованный stable tag
- публиковать APK с меньшим `versionCode`
- выпускать hotfix с тем же stable `versionName`, даже если `versionCode` выше
- выпускать stable continuity update из другого GitHub repository

## Local Preflight

Минимальный preflight: `docs/base-verification.md`

Локальная проверка stable tag contract:

```bash
nix shell nixpkgs#flutter --command \
  dart tool/check_release_continuity.dart \
    --github-repository makriq-org/FlClashM \
    --github-ref-name v0.10.0
```

Локальная проверка готового `dist/` после полного release build:

```bash
nix shell nixpkgs#flutter --command \
  dart tool/check_android_release_artifacts.dart \
    --dist dist \
    --release-channel stable \
    --github-ref-name v0.10.0 \
    --github-repository makriq-org/FlClashM
```
