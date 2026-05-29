# Compatibility Boundaries

Этот документ фиксирует legacy-идентификаторы, которые в `FlClashM` оставлены намеренно как слой совместимости, а не как незавершенный rebrand.

## Что уже должно быть ребрендировано

- app label, launcher assets, widget labels и notification channel display names
- release artifacts и release metadata
- release repository: `makriq-org/FlClashM`
- Android continuity package: `com.makriq.flclash`
- product docs и пользовательские action examples

## Что оставлено как compatibility layer

- Dart package name `flclashx`
  - Причина: дешевый upstream merge и отсутствие массовой churn по imports.
- Android namespace/class package `com.follow.clashx*`
  - Причина: текущая база и generated wiring все еще собраны вокруг этого namespace.
- provider header namespace `flclashx-*`
  - Причина: уже существующая provider ecosystem и подписки.
- deep link scheme `flclashx://`
  - Причина: не ломать старые ссылки и интеграции.
- Quick Settings tile service class `FlClashXTileService`
  - Причина: уже закрепленные пользователем tiles должны переживать update.
- Android notification channel IDs `FlClashX` и `FlClashX_Subscription`
  - Причина: сохранить пользовательские notification preferences после update.
- persisted Android helper filenames `flclashx_*`
  - Причина: continuity always-on/runtime state across updates.
- TV sync payload type `flclashx_tv_sync`
  - Статус: принимается как legacy input.
  - Новый canonical type: `flclashm_tv_sync`.

## Правило на будущее

Если новый public/product surface можно назвать `FlClashM` без поломки continuity, так и нужно делать.

Если legacy-имя нужно оставить, это должно быть:

- явно локализовано в compatibility boundary
- коротко объяснено в коде или документации
- не использовано как default для новых интеграций
