# Runtime

## Цель runtime-слоя

Runtime слой должен быть независим от UI и от provider-specific деталей.

Клиент подготавливает runtime через цепочку:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan`

После этого запуском занимается:

`EngineManager -> EngineAdapter`

## Текущее состояние

Сейчас в коде уже есть базовый Android runtime bootstrap:

- Flutter UI стартует через `AppBootstrap`
- Android quick actions обслуживает `AndroidEntrypoint`
- runtime config собирается в `GlobalState.patchRawConfig`
- Android policy применяется через `AndroidSecurityPolicy`
- запуск/остановка VPN идут через Android service bridge

## Ограничения

- `main.dart` не должен знать про tile intents, notification policy и Android runtime детали.
- Provider headers не должны определять runtime floor.
- Engine-specific логика не должна разъезжаться по UI, controller и service bridge одновременно.
- Desktop runtime path не должен участвовать в продуктовой сборке и релизе.

## Целевые runtime контракты

### `RawProfile`

Вход:

- профиль
- локальные override
- metadata/hints от провайдера

Выход:

- нормализованное описание профиля без platform side effects

### `ProfileCompiler`

Вход:

- `RawProfile`
- локальные настройки клиента

Выход:

- platform-agnostic runtime config

### `SecurityPolicy`

Вход:

- compiled config
- platform profile

Выход:

- config после client-side hardening

### `RuntimePlan`

Вход:

- hardened config

Выход:

- полный план запуска runtime и helpers

### `EngineManager`

Ответственность:

- lifecycle engine/runtime
- orchestration adapters
- restart/update boundaries

### `EngineAdapter`

Ответственность:

- конкретный контракт для `mihomo`, потом `olcrtc`, `naiveproxy`

## Будущая интеграция runtime

Порядок интеграции:

1. `mihomo` как базовый engine
2. `olcrtc` как отдельный adapter
3. `naiveproxy` как отдельный adapter
4. `byedpi` как helper-only integration
