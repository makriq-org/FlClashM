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
- Security-critical поведение не должно зависеть от provider headers.
- Перед любой новой runtime-интеграцией зафиксировать: место в архитектуре,
  контракт, ограничения безопасности, update/rollback path.

## Архитектура

Главная цепочка:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan -> EngineManager -> EngineAdapter`

Слои:

1. `FlClashX Base` — UI, навигация, базовый runtime path.
2. `Product Layer` (`lib/product/**`) — компиляция профиля, security policy, обновления.
3. `Runtime Layer` — `mihomo` (baseline), built-in nodes: `naiveproxy`, `olcrtc`, `byedpi`.
4. `Platform Layer` — Android VPN, foreground service, installer bridge.

Base-код вне `lib/product/**` знает о product layer только через разрешенные
touchpoints из `tool/product_touchpoints.json`.

## Документация

- `docs/README.md` — обзор документации.
- `docs/user-guide/README.md` — руководство пользователя.
- `docs/user-guide/profiles.md` — встроенные узлы ByeDPI, OlcRTC, NaiveProxy.
- `docs/user-guide/split-tunneling.md` — раздельное туннелирование через профиль.
- `docs/user-guide/provider-hints.md` — подсказки провайдера.
- `docs/development/architecture.md` — слои и сервисы.
- `docs/development/runtime.md` — среда выполнения и встроенные узлы.
- `docs/development/security.md` — политика безопасности.
- `docs/development/release-contract.md` — релизы.
- `docs/development/upstream-sync.md` — синхронизация с FlClashX.
- `docs/development/verification.md` — проверка сборки.

## Текущие ограничения

- В дереве еще есть legacy desktop/base код — он не является целью релизов.
- Часть UI/lifecycle wiring идет через legacy `GlobalState`/controller — не ломать
  baseline при cleanup.
- Cold-start и runtime-node path нужно проверять на реальных Android ABI после
  каждой новой built-in node интеграции.
