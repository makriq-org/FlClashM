# Релизы

## Версия и состав

`pubspec.yaml` хранит `MAJOR.MINOR.PATCH[-preN]+versionCode`.
Тег точно совпадает с `v<versionName>`, включая `-preN`.
Релизный `applicationId` — `com.makriq.flclash`.
Правила повышения версии, подготовки ветки и тега — в [AGENTS.md](../../../../AGENTS.md).

Выпуск содержит:

- `FlClashM-android-universal.apk`;
- APK для `arm64-v8a`, `armeabi-v7a` и `x86_64`;
- `FlClashM-android-release.aab`;
- SHA-256 каждого файла и `FlClashM-android-release-metadata.json`.

CI проверяет границы форка, непрерывность релиза, тесты и анализ, собирает
артефакты, проверяет подписи APK/AAB и создаёт метаданные. Затем публикует
артефакты и подписанный каталог обновлений на SourceForge и GitHub.

## Доставка обновлений

SourceForge — основной источник APK, GitHub — запасной. Указатели каналов:

- `https://flclashm.sourceforge.io/update/stable.json`;
- `https://flclashm.sourceforge.io/update/pre.json`.

Рядом с JSON публикуется двоичная подпись `.sig`. Приложение проверяет её
встроенным ключом Ed25519 до разбора JSON. Каталог содержит SHA-256 и зеркала
каждого APK. Заголовки провайдера не влияют на доверие к обновлению.

`versionCode` каталога равен максимальному фактическому коду готовых APK.
Код каждого APK извлекается Android SDK: Flutter добавляет ABI-смещение при
`--split-per-abi`, поэтому значение из `pubspec.yaml` напрямую не подходит.
GitHub использует те же коды из release-metadata.

Сначала файлы загружаются в `releases/<tag>`, затем публикуется подпись указателя
и последним сам указатель. Нужны секреты `APP_UPDATE_SIGNING_KEY`,
`SOURCEFORGE_SSH_KEY` и `SOURCEFORGE_USERNAME`.

## Откат

Для каждого канала приложение запоминает наибольшие `versionCode` и время
публикации и отклоняет старые подписанные каталоги. Исправление выпускается
новой версией с большим кодом; Android также запрещает понижение APK.
При смене ключа сначала выпускается переходная версия с новым открытым ключом.
