# Релизный контракт

FlClashM выпускает только Android-артефакты из `makriq-org/FlClashM` с
`applicationId` `com.makriq.flclash`. Эти значения и сертификат подписи входят в
проверяемую непрерывность обновлений.

## Теги и версии

- стабильный тег: `v<versionName>`, например `v0.10.6`;
- предварительный тег: `v<versionName>-<suffix>`, например `v0.10.6-pre5`;
- версия Flutter берётся из тега без начальной `v`;
- `versionCode` должен быть не ниже floor из
  `tool/release_continuity_baseline.json` и расти для каждого исправляющего
  выпуска.

Для каждого тега в `CHANGELOG.md` нужна одноимённая секция `## <tag>`. Workflow
формирует release notes из неё; отсутствующая секция останавливает публикацию.

## Артефакты

| Файл | Назначение |
| --- | --- |
| `FlClashM-android-universal.apk` | Универсальный APK |
| `FlClashM-android-arm64-v8a.apk` | 64-битный ARM APK |
| `FlClashM-android-armeabi-v7a.apk` | 32-битный ARM APK |
| `FlClashM-android-x86_64.apk` | x86_64 APK |
| `FlClashM-android-release.aab` | Android App Bundle |
| `FlClashM-android-release-metadata.json` | Версия, commit, канал, signer и состав выпуска |

Для каждого файла создаётся sidecar `.sha256`. До публикации tool-гейт проверяет
полный состав, имена, канал, метаданные, версию и подпись всех APK/AAB.

## Порядок конвейера

1. Product boundaries, release continuity, base drift, тесты и targeted analyze.
2. Сборка runtime assets и `mihomo` для поддерживаемых ABI.
3. Параллельная сборка split APK, universal APK и AAB с release-сертификатом.
4. Проверка certificate continuity всех Android-артефактов.
5. Генерация metadata и SHA-256, затем проверка полного каталога `dist`.
6. Формирование release notes из `CHANGELOG.md`.
7. Создание и Ed25519-подпись каталога обновления.
8. Публикация неизменяемого `releases/<tag>` на SourceForge.
9. Публикация сначала `.sig`, затем channel pointer JSON.
10. Создание GitHub Release с теми же артефактами и notes.

SourceForge публикуется до GitHub Release: встроенный апдейтер не должен увидеть
каталог, файлы которого ещё недоступны в основном хранилище.

## Доставка обновлений

Клиент читает фиксированные указатели:

- `https://flclashm.sourceforge.io/update/stable.json`;
- `https://flclashm.sourceforge.io/update/pre.json`.

Рядом находится двоичная подпись `.sig`. После Ed25519-проверки каталог задаёт
SHA-256 и упорядоченные URL зеркал для каждого ABI. SourceForge — основной
источник, GitHub — запасной; provider headers не участвуют в выборе доверия.

Приложение хранит наибольшие увиденные `versionCode` и время публикации отдельно
для stable/pre и отвергает повтор старого подписанного каталога. Downgrade также
ограничивает Android package manager.

## Ключи и откат

Release workflow требует Android signing secrets, ключ Ed25519 каталога и
доступ SourceForge. Закрытые ключи не хранятся в репозитории. Открытый ключ
каталога и fingerprint Android-сертификата закреплены в baseline и проверяются
гейтами.

Опубликованный каталог `releases/<tag>` неизменяем. Ошибка исправляется новым
тегом с большим `versionCode`; перезаписывать старый APK или возвращать старый
pointer нельзя. Для ротации Ed25519 сначала выпускается переходная версия
приложения с новым открытым ключом, и только затем новым ключом подписывается
следующий каталог.

## Локальная проверка контракта

```bash
dart tool/check_release_continuity.dart
dart tool/check_release_continuity.dart \
  --github-repository makriq-org/FlClashM \
  --github-ref-name v0.10.6-pre5
```

Проверки готовых Android-файлов требуют собранный `dist` и release signing;
обычный документационный или продуктовый PR не генерирует релиз локально.
