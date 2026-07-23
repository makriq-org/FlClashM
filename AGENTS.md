# AGENTS.md

## Контекст

- Проект: `FlClashM` — Android-клиент для `mihomo`, форк `FlClashX`.
- Текущий режим: `maintenance/cheap-upstream`.
- `applicationId`: `com.makriq.flclash` — не менять.
- Релизный канал: `makriq-org/FlClashM`.

## Правила работы

- Писать кратко и по существу.
- Предпочитать простые, предсказуемые и обратимые решения.
- Не размазывать product-логику по базе без явной архитектурной причины.
- Любое изменение base-файла вне `lib/product/**` допустимо только через
  product layer + запись в `tool/product_touchpoints.json`, либо с записью в
  `tool/base_drift_allowlist.json`; это проверяет CI через
  `dart tool/check_base_drift.dart`.
- Security-critical поведение не должно зависеть от provider headers.
- Перед любой новой runtime-интеграцией зафиксировать: место в архитектуре,
  контракт, ограничения безопасности, update/rollback path.

## Архитектура

Главная цепочка:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan -> EngineManager -> EngineAdapter`

Слои:

1. `FlClashX Base` — UI, навигация, базовый runtime path.
2. `Product Layer` (`lib/product/**`) — форковая логика, security policy, обновления и fork-only страницы.
3. `Runtime Layer` — `mihomo` (baseline), built-in nodes: `naiveproxy`, `olcrtc`, `byedpi`.
4. `Platform Layer` — Android VPN, foreground service, installer bridge.

Base-код вне `lib/product/**` знает о product layer только через разрешенные
touchpoints из `tool/product_touchpoints.json`. Живые `lib/views/**` не
копируются в product-слой: они остаются апстримными файлами с минимальными
зарегистрированными хуками. Fork-only страницы держать в `lib/product/pages/**`
с тонким mount-файлом в base только когда без этого страница недостижима. Любой файл в `lib/product/**`,
объявляющий виджет или фабрику `Widget`, должен иметь запись с причиной в
`allowedProductUi` из `tool/product_touchpoints.json`; это проверяет CI.

## Документация

- `i18n/ru/docs/README.md` — обзор документации.
- `i18n/ru/docs/user-guide/README.md` — руководство пользователя.
- `i18n/ru/docs/user-guide/getting-started.md` — установка и первое подключение.
- `i18n/ru/docs/user-guide/profiles.md` — встроенные узлы ByeDPI, OlcRTC, NaiveProxy.
- `i18n/ru/docs/user-guide/split-tunneling.md` — раздельное туннелирование через профиль.
- `i18n/ru/docs/user-guide/provider-hints.md` — подсказки провайдера.
- `i18n/ru/docs/development/README.md` — вход в документацию для разработчиков.
- `i18n/ru/docs/development/architecture.md` — слои и сервисы.
- `i18n/ru/docs/development/runtime.md` — среда выполнения и встроенные узлы.
- `i18n/ru/docs/development/security.md` — политика безопасности.
- `i18n/ru/docs/development/release-contract.md` — релизы.
- `i18n/ru/docs/development/upstream-sync.md` — синхронизация с FlClashX.
- `i18n/ru/docs/development/verification.md` — проверка сборки.

## Текущие ограничения

- В дереве еще есть legacy desktop/base код — он не является целью релизов.
- Часть UI/lifecycle wiring идет через legacy `GlobalState`/controller — не ломать
  baseline при cleanup.
- Cold-start и runtime-node path нужно проверять на реальных Android ABI после
  каждой новой built-in node интеграции.

## Процедура обновления апстрима

Перед синком подтянуть ссылки и обновить локальную ветку апстрима: `git fetch upstream`
и затем `git fetch origin`. Дальше обновление вести от `upstream/dev`: создать
рабочую ветку от целевой ветки форка, выполнить `git merge upstream/dev` и
разрешить конфликты (Dart-пакет форка называется `flclashx`, как в апстриме,
поэтому нормализация импортов не нужна). Для типовых повторяющихся конфликтов
включён `rerere`, поэтому
после первого ручного разрешения следующих синках Git сам подставит уже сохранённый
вариант; если нужно прогреть базу, сделать это на временной ветке, один раз
разрешить знакомые конфликты, убедиться в результате и удалить временную ветку без
мусорных коммитов.

После мёрджа сразу проверить новый base-дрейф командой
`dart tool/check_base_drift.dart`. Чекер сравнивает дерево с merge-base относительно
`upstream/dev`, сверяет все изменённые пути из `lib`, `android` и `core` из HEAD,
индекса и рабочего дерева с
`tool/base_drift_allowlist.json` и падает, если появился новый base-файл вне
бюджета. Если в окружении нет `upstream`, передать merge-base через
`--merge-base=<sha>` или `BASE_DRIFT_MERGE_BASE`.

Финальный прогон гейтов перед фиксацией синка: `dart tool/check_product_boundaries.dart`,
`flutter test test/product` и `dart tool/check_base_drift.dart`. Если base-чекер
показал новый путь, сначала либо вынести логику в разрешённые точки подключения,
либо осознанно добавить запись в `tool/base_drift_allowlist.json` с причиной и
корзиной, и только потом завершать синк.
