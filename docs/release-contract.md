# Контракт релизов Android

## Область

Этот документ фиксирует контракт релизов для Android в `FlClashM`: непрерывность,
обновление и откат не должны зависеть от ручного знания.

## Источники истины

- `tool/release_continuity_baseline.json`
  - пакет непрерывности: `com.makriq.flclash`
  - канал релизов непрерывности: `makriq-org/FlClashM`
  - ожидаемые имена секретов релизной подписи
  - ожидаемый SHA-256 сертификата подписи
  - ожидаемые артефакты релиза Android
  - имя файла метаданных релиза
  - `versionCodeFloor` и провенанс последнего публичного релиза
  - начальный baseline импортирован из `FlClash-my`
- `pubspec.yaml`
  - `versionName`
  - `versionCode`
- `setup.dart`
  - именование артефактов Android
  - путь упаковки split-ABI, universal и AAB
- `android/app/build.gradle.kts`
  - мост релизной подписи
  - `applicationId` Android
- `.github/workflows/build.yaml`
  - конвейер тег-релизов
  - защиты метаданных, контрольных сумм и артефактов

## Правила релизов

- Стабильный тег обязан быть ровно `v<versionName>`.
- Тег предварительного релиза обязан начинаться с `v<versionName>-`.
- `versionCode` обязан быть строго выше `versionCodeFloor`.
- После каждого публичного релиза непрерывности нужно обновлять `versionCodeFloor`
  на фактически опубликованный `versionCode`. Локальная защита не ходит в GitHub
  за историей и опирается только на baseline из git.
- Стабильное исправление или откат релиза обязаны двигать вперёд и `versionName`,
  и `versionCode`. Android требует больший `versionCode` для установки; встроенный
  загрузчик сравнивает релизы по версии тега.
- `applicationId` обязан оставаться `com.makriq.flclash`.
- Релизная подпись обязана использовать полный набор секретов:
  `KEYSTORE`, `KEY_ALIAS`, `STORE_PASSWORD`, `KEY_PASSWORD`.
- Мост подписи обязан принимать keystore как в формате `JKS`, так и в `PKCS12`
  без смены набора секретов.
- Опубликованный APK обязан иметь тот же SHA-256 подписи, что и текущий baseline
  в `tool/release_continuity_baseline.json`.
- С `2026-05-29` старый ключ непрерывности от `FlClash-my` считается утраченным.
  Обновление поверх старых установок больше не гарантируется — для перехода на
  новый ключ требуется переустановка.
- Стабильный релиз публикуется только в `makriq-org/FlClashM`.

## Состав релиза

Каждый тег-релиз обязан содержать:

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`
- `FlClashM-android-release-metadata.json`

Стабильный релиз дополнительно обязан содержать `.sha256` для каждого файла.

`FlClashM-android-release-metadata.json` фиксирует:

- тег
- репозиторий
- канал релизов
- `versionName`
- `versionCode`
- встроенный `coreVersion`
- провенанс baseline непрерывности
- ожидаемые артефакты Android

## Конвейер

Рабочий процесс тег-релизов: `.github/workflows/build.yaml`

1. `Check release continuity`
   — проверяет пакет, репозиторий и подпись; проверяет контракт тега против `pubspec.yaml`.
2. `Build Android release artifacts`
   — собирает split APK, universal APK и AAB через `setup.dart`.
3. `Assert Android release signing continuity`
   — проверяет, что arm64-релиз APK подписан правильным сертификатом.
4. `Generate release metadata`
   — пишет машиночитаемый провенанс в `dist/FlClashM-android-release-metadata.json`.
5. `Generate sha256`
   — только для стабильного релиза.
6. `Assert Android release artifacts`
   — проверяет наличие ожидаемых файлов; для стабильного проверяет совпадение `.sha256`;
   проверяет, что metadata JSON совпадает с источником истины.
7. Публикация
   — стабильный: GitHub Release; предварительный: GitHub pre-release.

## Путь обновления

- Загрузчик обновлений читает только `https://api.github.com/repos/makriq-org/FlClashM/releases/latest`.
- Встроенный загрузчик работает только в стабильном окружении приложения.
- Кандидат на обновление определяется по версии стабильного тега, а не по `versionCode`.
- APK выбирается по ABI; если ABI-специфичный файл отсутствует, используется universal APK.
- Путь установки обязан пройти проверку SHA256: сначала по inline-`digest`, если
  GitHub его отдаёт; иначе по sibling-файлу `.sha256`.

Стабильный релиз без корректных контрольных сумм не считается валидным источником обновления.

## Откат релиза

Откат — не повторная публикация старого APK и не переиспользование старого тега.

Если плохой стабильный релиз уже опубликован:

1. Выбрать последний рабочий коммит или коммит с исправлением.
2. Поднять `pubspec.yaml` на новый `versionName`.
3. Поднять `versionCode` выше уже опубликованного плохого релиза.
4. Выпустить новый стабильный тег по правилу `v<versionName>`.
5. Не менять секреты, `applicationId` и репозиторий релизов.

Нельзя:

- Переиспользовать уже опубликованный стабильный тег.
- Публиковать APK с меньшим `versionCode`.
- Выпускать исправление с тем же стабильным `versionName`.
- Публиковать обновление непрерывности из другого репозитория GitHub.

## Обновление floor после релиза

После каждого публичного релиза непрерывности:

1. Зафиксировать фактически опубликованный `versionCode`.
2. Обновить `versionCodeFloor` в `tool/release_continuity_baseline.json`.
3. Обновить провенанс в `continuityBaseline`:
   - `sourceTag`
   - `publishedAt`
   - `sourcePubspecVersion`
4. Поднять `pubspec.yaml` на версию с build suffix строго выше нового floor.
5. Прогнать `dart tool/check_release_continuity.dart` и дождаться зелёного CI.

## Локальная предварительная проверка

Минимальная предварительная проверка: `docs/base-verification.md`

Локальная проверка контракта стабильного тега:

```bash
nix shell nixpkgs#flutter --command \
  dart tool/check_release_continuity.dart \
    --github-repository makriq-org/FlClashM \
    --github-ref-name v0.10.0
```

Локальная проверка готового `dist/` после полной сборки релиза:

```bash
nix shell nixpkgs#flutter --command \
  dart tool/check_android_release_artifacts.dart \
    --dist dist \
    --release-channel stable \
    --github-ref-name v0.10.0 \
    --github-repository makriq-org/FlClashM
```
