# Полная интеграция пользовательских возможностей апстрима

Источник: `pluralplay/FlClashX`, `upstream/0.5.0-dev`,
`5b38c0c7dfba726b8335407d0df5e6205e2d9bfa`.
Целевая ветка PR: `dev`. PR не сливать; пользователь проверяет результат сам.
Ревью по явному запросу пользователя: `@coderabbit` вместо `@codesmith-bot`.

## Обязательный результат

- Полный новый интерфейс: dashboard, профили, прокси, настройки, темы, меню,
  навигация, редактор, соединения/запросы и переводы.
- Конструктор профилей, ссылки серверов, группы, провайдеры, правила и цепочки.
- Переопределение отдельных DNS/NTP/sniffer-параметров; Android VPN остаётся
  под нашей политикой. Существующие значения и профили сохраняют поведение.
- Выходной IP, проверки сервисов, история DNS, управление ресурсами.
- ByeDPI/OlcRTC/StormDNS/NaiveProxy, обновления APK, диагностика, независимый
  Android backend и изолированный validator сохраняются.
- Полная интеграция проходит анализ, содержательные тесты и сборку Android;
  заглушки, отключённые кнопки и второй источник истины результатом не являются.

## Контракты

Go API v1 и текущие команды `profile.*`, `settings.*`, `subscription.*`,
`runtime.*`, `proxy.select`, `backup.*`, `blob.*`, `ui.attach` сохраняются.
`BackendClient` остаётся транспортом Flutter. Снимки Go — источник истины.
Существующие ID профилей остаются строками без потери/хеширования.
Новые authoring-объекты и настройки сохраняются в Go; SQL/SharedPreferences
Flutter не могут быть авторитетным постоянным хранилищем.

Расширение конструктора:

- `authoring.snapshot`: `{revision, profiles, collections}`; коллекции `scripts`, `rules`,
  `disabledRules`, `proxyGroups`, `clashProviders`, `customProxies`, `proxyDialers`,
  `iconRecords`, `iconSets` — JSON-массивы деклараций в формате моделей апстрима;
  ссылки на профиль — строковые `profileId`.
- `authoring.replace`: `{expectedRevision, collections, profiles?, deletedProfileIds?}`;
  метаданные, удаления и декларации сохраняются одной CAS-транзакцией. Квитанция
  содержит общую revision. Snapshot также захватывает profiles под тем же mutex.
- Строки scripts содержат `content`; локальные rule providers содержат
  `contentBase64`. `authoring.resource.read/update` адресуют только разрешённую
  коллекцию и ID; загрузки и материализация файлов принадлежат Go.
- `profile.inspect` возвращает исходный config, сведения base и outbounds;
  `profile.render/export` передают большой результат через blob;
  `profile.validate` принимает blob token. `authoring.evaluate` использует Goja
  для предварительного просмотра без изменения runtime.
- Custom-профили собирает Go из сохранённых деклараций; UI не отправляет
  исполняемый RuntimePlan и не применяет конфигурацию самостоятельно.
- Операции парсинга ссылок/конфига доступны через прикладной Go API; платформенные
  пути к произвольным файлам интерфейс не передаёт. Большие данные — blob API.

Диагностические engine helpers подключает интегратор; изменения runtime идут
через RuntimeCoordinator, чтение не должно задерживать Stop.
Окончательные JSON схемы новых методов фиксировать здесь при уточнении, сохраняя
обратную совместимость API v1 и явно сообщая интегратору о необходимых изменениях.

## Нативный редактор

Rust-компонент апстрима размещается в UI-слое как реализация текстового редактора.
Он не получает владение профилями, подписками или runtime. Выполнение скриптов
предварительного просмотра также направляется в Go API. Версия Rust 1.99.0 и
зависимости закреплены; Nix предоставляет Android std декларативно, CI использует
ту же версию. Обновление: исходники plugin, Cargo.lock и toolchain меняются вместе.
Формат хранения остаётся Go-каталогом, без Flutter SQLite. Старый бинарник со
строгим decoder не понимает поле authoring: перед откатом нужно сохранить каталог
и восстановить совместимый backup. Полные контракты — в
`core/backend/authoring/CONTRACT.md` и `lib/product/backend/upstream_contract.md`.

## Владение файлами при параллельной работе

- UI: `lib/**`, Flutter-тесты нового интерфейса, визуальные локальные plugins,
  assets/arb новых экранов; существующий `lib/product/**` сохранять/адаптировать.
  `pubspec.yaml` — только нужные изменения зависимостей, согласовать интегратору.
- Go domain: `core/backend/**` и его тесты, включая authoring и компиляцию.
  Engine helpers вне этого каталога только по согласованию с интегратором.
- Android: `android/**`, Kotlin/instrumentation-тесты, Android transport.
- Интегратор: `core/*.go`, engine adapters/diagnostic helpers, зависимости Go,
  `pubspec.lock`, setup/Nix/CI/guards, документация, CHANGELOG и объединение.

Каждый исполнитель работает в собственном worktree, делает русские тематические
коммиты без AI-трейлеров и сообщает их SHA. Не менять ветки другого исполнителя,
не откатывать чужие правки. Никаких push/PR/merge в `dev` у исполнителей.

## Воспроизводимая генерация

`nix develop -c make generate` запускает `tool/generate_flutter.dart`: настоящий
Flutter SDK summary строится с sky_engine embedder из package_config, даже если
Nix разрешил Dart в standalone SDK. Затем работает обычный build_runner; shared
pub cache не меняется. После clean wrapper запускается снова. Drift combining
builder выводит database.g.dart в lib/database/generated.
