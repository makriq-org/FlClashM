# Релизы

## Правила версий

- **Стабильный тег:** `v<versionName>`
- **Предварительный:** `v<versionName>-<suffix>`
- `applicationId`: `com.makriq.flclash`

## Состав релиза

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

Стабильный релиз содержит `.sha256` для каждого файла.

## Конвейер

1. Проверка непрерывности
2. Сборка артефактов
3. Проверка подписи
4. Генерация метаданных
5. Генерация контрольных сумм (стабильный)
6. Публикация на GitHub
