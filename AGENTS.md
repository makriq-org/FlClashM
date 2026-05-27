# AGENTS.md

## Контекст

- Этот репозиторий — новый продуктовый bootstrap `FlClashM`.
- База кода взята из `FlClashX`.
- Android continuity обязательно сохраняется относительно `FlClash-my`:
  - `applicationId`: `com.makriq.flclash`
  - релизная подпись: те же секреты `KEYSTORE`, `KEY_ALIAS`, `STORE_PASSWORD`, `KEY_PASSWORD`
  - `versionCode` каждой новой версии должен быть выше последней публичной версии `FlClash-my`
- Новый целевой release channel: `makriq-org/FlClashM`.

## Правила работы

- Писать кратко и по существу.
- Предпочитать простые, предсказуемые и обратимые решения.
- Любое нетривиальное решение документировать.
- Не размазывать product-логику по базе без явной архитектурной причины.
- Security-critical поведение не должно зависеть от provider headers.
- Перед любой новой runtime-интеграцией сначала определить:
  - место в архитектуре
  - контракт
  - ограничения безопасности
  - сценарий обновления и отката

## Архитектурная цель

Главная цепочка:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan -> EngineManager -> EngineAdapter`

Слои:

1. `FlClashX Base`
- UI
- навигация
- базовый runtime path
- то, что удобно обновлять из upstream

2. `Product Layer`
- логика `FlClashM`
- compile pipeline
- security policy
- update logic

3. `Runtime Layer`
- `mihomo`
- `olcrtc`
- `naiveproxy`

4. `Helper Layer`
- `byedpi` как helper, а не как основной engine

5. `Platform Layer`
- Android VPN
- permissions
- installer/update bridge
- foreground service

## Принципы

- `FlClashX` использовать как обновляемую базу, а не как место для хаотичных патчей.
- Все продуктовые изменения по возможности держать в узком adapter/product layer.
- `olcrtc` и `naiveproxy` подключать как engine adapters.
- Android security policy определяется клиентом, а не подпиской.
- Поставщик может передавать metadata и hints, но не ослаблять security floor.

## Текущий этап

Фаза: `bootstrap/rebrand`

Цели:

1. Поднять новый репозиторий `FlClashM` на базе `FlClashX`.
2. Сохранить Android continuity из `FlClash-my`.
3. Зафиксировать архитектуру и правила до начала большой миграции.

## Поэтапный план

1. Bootstrap и rebrand
- новый репозиторий
- новое имя продукта
- новый release channel
- сохранение Android continuity

2. Выделение seam в базе
- profile loading
- profile compile
- runtime start/stop
- Android VPN policy
- update/install path

3. Встраивание product layer
- `ProfileCompiler`
- `SecurityPolicy`
- `EngineManager`
- `UpdateService`

4. Перенос текущих функций из `FlClash-my`
- updater
- split tunneling
- нужные Android policy-части

5. Стабилизация базы
- сборка
- запуск VPN
- обновление
- регрессии

6. Интеграция runtime по одному
- `olcrtc`
- `naiveproxy`
- `byedpi`

## Что документировать обязательно

- новые контракты модулей
- security-sensitive решения
- миграции данных и update path
- ограничения каждого engine/helper

## Ближайшие документы

- `docs/architecture.md`
- `docs/runtime.md`
- `docs/security-policy.md`
- `docs/migration-plan.md`
