# Compatibility Boundaries

Этот документ фиксирует границы совместимости, которые в `FlClashM` еще остаются после завершения ребрендинга.

## Что уже ребрендировано

- app label, launcher assets, widget labels и notification channel IDs
- release artifacts и release metadata
- release repository: `makriq-org/FlClashM`
- Android continuity package: `com.makriq.flclash`
- product docs и пользовательские action examples
- product deep link: `flclashm://`
- product custom headers: `flclashm-*`
- TV sync payload type: `flclashm_tv_sync`

## Что еще остается как техническая совместимость

- Android namespace/class package `com.follow.clashx*`
  - Причина: текущая Android-база и generated wiring все еще собраны вокруг этого source namespace.
  - Статус: это внутренний кодовый слой, а не публичный брендовый контракт.
- старые Android helper files `flclashx_*`
  - Причина: нужны только как вход для одноразового переноса данных в `flclashm_*`.
  - Статус: новые записи идут только в `flclashm_*`.

## Правило на будущее

Если появляется новый публичный идентификатор, он должен называться в стиле `FlClashM` или `flclashm`.

Если временно остается старое имя, это должно быть:

- явно локализовано в compatibility boundary
- коротко объяснено в коде или документации
- не использовано как default для новых интеграций
