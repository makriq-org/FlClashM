# 🛠 Сборка и сопровождение

[← README](../../../README.md) · **Русский** · [English](../../en/docs/maintenance.md) · [中文](../../zh/docs/maintenance.md) · [فارسی](../../fa/docs/maintenance.md)

Команды для работы с репозиторием и контракты, которые нужно сохранить при изменениях. Правила веток, коммитов и PR — в [AGENTS.md](../../../AGENTS.md).

[Сборка](#build) · [Архитектура](#architecture) · [Данные](#data) · [Безопасность](#security) · [Диагностика](#diagnostics) · [Апстрим](#upstream) · [Релиз](#release)

<a id="build"></a>

## 🏗 Сборка и проверки

Окружение NixOS задано в `flake.nix`: Flutter 3.47.x, Go 1.27.2, JDK 17, SDK 37.0 и NDK 28.0.13004108/28.2.13676358. Конфигурацию окружения меняйте декларативно.

```bash
nix develop -c make dev
nix develop -c make check
nix develop -c make go-check
```

`make check` проверяет product/base, GitHub Actions, релизный контракт, тесты `test/product`/`test/tool`, ошибки во всём `lib` (`analyze-app`) и выборочный анализ. `make go-check` подготавливает vendor, проверяет gofmt для `core/backend`, затем запускает vet, host-тесты и race detector всего `core` с `GOFLAGS=-mod=vendor`; нужен C-компилятор. APK: `build/app/outputs/flutter-apk/app-debug.apk`.

<details>
<summary>Без Nix и отдельная тестовая установка</summary>

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --debug --target-platform android-arm64
```

Для независимой диагностической установки добавьте `ORG_GRADLE_PROJECT_backendDiagnostic=true` к команде `flutter build apk --debug --target-platform android-arm64`. Пакет — `com.makriq.flclash.backendcheck`; ручной CI с `backend_test` использует `.backendtest`. Обновление с сохранением данных: `adb install -r -t`.

Для упрощённой локальной сборки тестового варианта используйте `ORG_GRADLE_PROJECT_backendTest=true flutter build apk --release --target-platform android-arm64` после подготовки ядра и ресурсов; пакет — `com.makriq.flclash.backendtest`. CI дополнительно передаёт `--dart-define=APP_ENV=pre` и `--dart-define=CORE_VERSION` со значением из `lib/core_version.dart`.

</details>

CI проверяет Go host/race, Dart/Flutter, Kotlin unit-тесты, сборки ARM64/armeabi-v7a и E2E на x86_64 с настоящими mihomo, validator, ByeDPI и TUN. Документация пропускает тяжёлые задания. Изменения Dart-моста UI/backend запускают E2E с настоящей Flutter-activity; ошибки instrumentation и необработанные исключения Flutter проваливают проверку. Эмулятор не заменяет реальные ARM-устройства: перед выпуском проверяйте режимы, узлы, подписки, смерть UI/`:remote`, сохранение Stop при восстановлении, смену сети и энергопотребление. Открытые замечания собраны в [#132](https://github.com/makriq-org/FlClashM/issues/132). Workflow `secret-scan` проверяет коммиты PR и push с помощью Gitleaks.

<a id="architecture"></a>

## 🧭 Архитектура

```text
RawProfile + Settings + Capabilities
  → Go Compiler + SecurityPolicy
  → immutable RuntimePlan
  → RuntimeCoordinator
  → mihomo / external processes / Android VPN
```

Flutter хранит представление и черновики, отправляет команды и читает снимки. `core/backend/**` владеет профилями, настройками, подписками, компиляцией и восстановлением; переносимый пакет проверяется без Android. `core/backend_host.go` подключает mihomo и отдельные процессы транспортов. Android предоставляет разрешения, foreground-службу, VPN/TUN, DNS и события ОС.

RuntimeCoordinator — единственный владелец изменяемого runtime. Backend живёт в `:remote` независимо от Flutter; `:validator` изолирует parser mihomo. `ui.attach` может заранее подготовить обычные узлы без VPN. Stop сохраняется до эффектов, отменяет подготовку и выключает VPN; готовые узлы могут остаться для задержек при открытом UI. Восстановление без UI после Stop их не запускает; reset и Close завершают всё.

Base-код обращается к `lib/product/**` через `tool/product_touchpoints.json`; виджеты регистрируются в `allowedProductUi`. Экраны `lib/views/**` остаются в базе с минимальными хуками. Прочие base-изменения объясняются в `tool/base_drift_allowlist.json`. Координацию и legacy SharedPreferences как источник состояния в Dart/Kotlin не возвращать.

<details>
<summary>Контракты backend при изменении runtime</summary>

**Desired** — сохранённое намерение; **Applied** — последний подтверждённый план; **Observed** — фактическое наблюдение, unknown, если состояние нельзя подтвердить. Неизменяемый RuntimePlan проверяется по версии и SHA-256. Подготовка отделена от очереди эффектов; context и поколение отсеивают поздние результаты. Ошибка возвращает подтверждённый план либо останавливает ресурсы. Revoke VPN сохраняет Stop и требует нового явного Start. Очередь ограничена 8 принятыми командами с резервом под Stop.

API, данные и план имеют независимые версии, сейчас `1`. Запрос: `apiVersion`, `operationId`, `method`, `params`; ответ: `result` или `error`. Повтор ID с тем же содержимым возвращает прежний результат, с другим — отклоняется. Ожидаются оба результата доменной и связанной `runtimeOperationId` операции. Timeout или смерть UI не отменяют работу; отмена — явная команда.

Основные методы: `snapshot`, `runtime.view`, `presentation`, `runtime.*`, `operation.get/cancel`, `settings.patch`, `profile.*`, `subscription.refresh`, `proxy.select`, `backup.export/restore`, `blob.*`, `engine.command`, `ui.attach`, `data.reset`. События имеют `instanceId`/sequence; переполнение требует resync. UI подписывается до снимка и показывает применённый выбор из `runtime.view`. Медленный подписчик не блокирует VPN.

</details>

<a id="data"></a>

## 💾 Сохранность данных

`backend-v1.json` хранит runtime-намерение, поколение, подтверждённый input/plan и runtime-квитанции; `application-v1.json` — журнал доменных операций (до 2 МиБ); `profiles.json` — каталог профилей и настройки. Все три файла записываются через atomic rename и fsync. Восстановление берёт последний подтверждённый input; незавершённые операции становятся interrupted. Ревизии защищают от поздней записи подписки/редактора. Однократная миграция сохраняет IDs, даты, исходные байты, неизвестные поля и большие целые.

ZIP сохраняет `config.json`, оригинальные профили и provider cache. Отсутствующий исходник не заменяется пустым файлом. Архив проверяется на обход путей, символические ссылки и чрезмерный объём распаковки. Binder-перенос: блоки 192 КиБ, до 128 МиБ на файл, 32 незавершённых переноса и 512 МиБ суммарно. Удаление последнего профиля сохраняет Stop; reset останавливает работу и сохраняет маркер миграции и монотонность поколений.

Go обновляет подписки и списки приложений без UI и сохраняет прежний кэш при сбое сети. Уведомления об истечении подписки имеют пороги 3/2/1/0 дней и «истекла»; Go сохраняет защиту от повторов, Android локализует показ.

<a id="security"></a>

## 🔒 Границы безопасности

Пути к бинарникам, каталог приложения, ABI, сертификаты и локальные порты задаёт доверенный host. Занятый порт узла отклоняется до запуска. Аргументы передаются без shell, SOCKS слушает loopback, Linux/Android завершают дочерние процессы при смерти host. Пакеты обычной, dev и тестовых установок исключены из VPN и используют разные диапазоны портов. Go SecurityPolicy применяется до проверки и фиксации плана. Пользовательский выбор VPN сохраняется; `androidsecure` выключает только mixed-port.

JS работает в Goja без доступа к API платформы, с ограничением времени и отменой. Сетевые ограничения публичных списков и проверок — в [настройке профиля](profiles.md#checks); приватные серверы подписок и списков приложений разрешены. HTTP controller проверяет secret до команд; произвольные config paths, upgrade и старые runtime setters закрыты. Внутренние журналы и исполняемые артефакты не публикуются через DocumentsProvider.

<a id="diagnostics"></a>

## 🩺 Диагностика

Приложение не отправляет телеметрию. Кнопка экспорта на экране логов создаёт ZIP журналов Dart, Android, mihomo и внешних узлов с `manifest.json` (версии, Android API/ABI, время и минимальное состояние). Профили, подписки, конфиги и IPC payload не включаются. Ключи, пароли, учётные данные, URL подписки и названия профилей удаляются до записи и повторно при экспорте.

Запись ограничена очередью и ротацией; медленный журнал не блокирует остановку узла. Android ограничивает строку 16 КиБ, Go — 4 КиБ с очередью 16 строк. Mihomo пишет без Flutter listener. Экспорт работает и без доступного `:remote`; ZIP имеет `schemaVersion`, правила очистки проверяются общими тестовыми векторами Dart/Kotlin.

<a id="upstream"></a>

## 🔄 Обновление апстрима и узлов

Создайте ветку от целевой ветки форка, выполните команды ниже и разрешите конфликты. Имя Dart-пакета остаётся `flclashx`. После merge сразу проверьте base drift; новые пути зарегистрируйте с причиной. Без upstream задайте `--merge-base=<sha>` или `BASE_DRIFT_MERGE_BASE`. Изменения runtime сначала выпускаются как `-preN` с проверкой на реальном Android.

```bash
git fetch upstream
git fetch origin
git merge upstream/dev
nix develop -c make check go-check
```

`tool/prepare_core.sh` пересоздаёт `core/vendor`, применяет патчи без fuzz и проверяет регрессию Mieru. Сборка использует `-mod=vendor`, общий module cache не меняется. Патчи: таймаут закрытого Mieru QUIC, HTTP command gate backend и синхронизация доступа к системному DNS. При обновлении проверяйте каждый патч; удаляйте исправленный апстримом патч с его вызовом, сохраняя vendor для оставшихся.

Версии, исходные коммиты, ABI и SHA-256 узлов закреплены в `lib/product/runtime/*_release.dart`; зависимости — в [tool/runtime_go_modules](../../../tool/runtime_go_modules/README.md), заметки о сборке — в [ресурсах](../../../assets/runtimes/). Обновление и откат меняют закрепления, зависимости и бинарники вместе; затем пересобираются и проверяются выпускаемые ABI.

<a id="release"></a>

## 📦 Выпуск и откат

Версия — `MAJOR.MINOR.PATCH[-preN]+ГГГГММДДnn` в `pubspec.yaml`. Несовместимые изменения требуют MAJOR, новые функции MINOR, исправления PATCH; учитывается и пользовательский эффект апстрима. `versionCode` каждого тега строго растёт. Тег `v<versionName>` ставится только на влитый в main коммит; релизный `applicationId` — `com.makriq.flclash`.

Создайте `release/<версия>`, перенесите пользовательские пункты Unreleased в секцию CHANGELOG с точным будущим тегом, обновите версию и выполните проверки. После PR/merge поставьте тег и запушьте его. CI проверит подписи APK/AAB и опубликует universal/ABI APK, AAB, SHA-256 и `FlClashM-android-release-metadata.json`. Пре-релизы видны в приложении только при включённой настройке.

SourceForge — основной источник, GitHub — запасной. Указатели stable/pre ниже проверяются по `.sig` ключом Ed25519 до разбора JSON. Каждый APK проверяется по SHA-256, затем Android проверяет подпись пакета. Заголовки провайдера на доверие к обновлениям не влияют.

При публикации каталог сохраняет общий `versionCode`, а для APK — `urls` (зеркала по порядку), `size` (байты), `sha256` и фактический `versionCode`. Стабильный выпуск обязательно содержит отдельные `.sha256` для файлов.

```text
https://flclashm.sourceforge.io/update/stable.json
https://flclashm.sourceforge.io/update/pre.json
```

<details>
<summary>Публикация и защита от понижения</summary>

Сначала публикуются файлы `releases/<tag>`, затем подпись указателя и последним JSON. Нужны `APP_UPDATE_SIGNING_KEY`, `SOURCEFORGE_SSH_KEY`, `SOURCEFORGE_USERNAME`. Коды APK извлекаются Android SDK: Flutter добавляет ABI-смещение при `--split-per-abi`. Код каталога — максимальный фактический код APK; GitHub использует те же коды из metadata.

Максимальные versionCode и время публикации хранятся отдельно по каналам. Старый подписанный каталог отклоняется, Android не допускает понижение APK. Откат — новый исправляющий выпуск с большим кодом. При смене ключа сначала выпускается переходная версия с новым открытым ключом.

</details>
