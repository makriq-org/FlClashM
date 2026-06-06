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

- `docs/architecture.md` — слои, границы, контракты сервисов.
- `docs/runtime.md` — runtime цепочка, контракты, built-in nodes.
- `docs/security-policy.md` — Android security floor, правила подписок.
- `docs/product-customization.md` — контракт `flclashm-*` подсказок.
- `docs/release-contract.md` — правила релизов, pipeline, rollback.
- `docs/upstream-maintenance.md` — как обновляться из `FlClashX`.
- `docs/base-verification.md` — локальная и CI-проверка.
- `docs/branding.md` — публичные идентификаторы.
- `docs/byedpi.md` — профильный контракт byedpi.

## Текущие ограничения

- В дереве еще есть legacy desktop/base код — он не является целью релизов.
- Часть UI/lifecycle wiring идет через legacy `GlobalState`/controller — не ломать
  baseline при cleanup.
- Cold-start и runtime-node path нужно проверять на реальных Android ABI после
  каждой новой built-in node интеграции.
