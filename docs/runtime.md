# Runtime

## Цель runtime-слоя

Runtime слой должен быть независим от UI и от provider-specific деталей.

Клиент подготавливает runtime через цепочку:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan`

После этого запуском занимается:

`EngineManager -> EngineAdapter`

## Текущее состояние

Сейчас runtime handoff фиксируется явно:

- `EngineManager` живет в `lib/product/runtime/engine_manager.dart`
- `EngineAdapter` контракт живет в `lib/product/runtime/engine_adapter.dart`
- `RuntimePlan.runtime` несет явный `RuntimeSelection`
- `RuntimeRegistry` является allowlist для engine/helper registrations
- текущий `mihomo` path завернут в `MihomoEngineAdapter` и зарегистрирован как default engine
- `RuntimePlan` теперь применяется через manager, а не напрямую из `controller/state`
- `AndroidEntrypoint` и legacy controller используют manager как orchestration boundary
- manager держит re-attach к уже запущенному runtime, refresh cold-start snapshot после setup/update и fail-fast guardrails для unsupported runtime selection

## Ограничения

- `main.dart` не должен знать про tile intents, notification policy и Android runtime детали.
- Provider headers не должны определять runtime floor.
- Engine-specific логика не должна разъезжаться по UI, controller и service bridge одновременно.
- Desktop runtime path не должен участвовать в продуктовой сборке и релизе.

## Целевые runtime контракты

### `RuntimeSelection`

Вход:

- один engine
- ноль или больше helpers

Выход:

- явный product-layer handoff между compile pipeline и runtime orchestration

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
- orchestration adapters через `RuntimeRegistry`
- restart/update boundaries
- compile-to-runtime handoff для `RuntimePlan`
- re-attach/polling для already-running Android runtime
- runtime switch только через явную stop/restart boundary

### `EngineAdapter`

Ответственность:

- конкретный контракт для `mihomo`, потом `olcrtc`, `naiveproxy`
- hide low-level bridge details (`clashCore`, Android service bridge, cold-start save path)

### `EngineRuntimeRegistration`

Должен определить:

- `RuntimeDescriptor`
- availability status
- update path
- rollback path
- `EngineAdapterFactory` только для реально поддержанного engine

### `HelperRuntimeRegistration`

Должен определить:

- `RuntimeDescriptor`
- helper attachment mode
- список поддержанных host engines
- update path
- rollback path

Helper не должен:

- владеть Android VPN/TUN lifecycle
- обходить client-side runtime policy
- появляться в selection без явного supervisor path

## Текущие регистрации

- `mihomo`
  - default engine
  - supported
  - update path: bundled Android core через `setup.dart` -> `libclash/android`
  - rollback path: текущий bundled core + existing cold-start path
- `olcrtc`
  - engine registration без включения
  - unavailable до pinned Android AAR, `gomobile` bridge, `SetProtector` handoff и client-side compile path для room/key settings
- `naiveproxy`
  - engine registration без включения
  - unavailable до packaged release binary, `config.json` generation и Android SOCKS-to-VPN bridge
- `byedpi`
  - helper-only registration
  - unavailable до helper supervisor и явного attach contract к engine

## Upstream constraints

- `olcrtc`: upstream описывает beta-статус, локальный SOCKS5 client mode, Android AAR через `mage mobile` и mobile API с `Start/Stop/IsRunning/SetProtector`.
- `naiveproxy`: upstream client ожидает локальный `config.json` и SOCKS listener, а для обновлений рекомендует следить за release tags, а не за `master`.
- `byedpi`: upstream инструмент сам является локальным SOCKS proxy и умеет transparent mode, поэтому в `FlClashM` он остается helper-only integration.

## Порядок включения новых runtime

1. `mihomo` как базовый engine
2. `olcrtc` как отдельный adapter
3. `naiveproxy` как отдельный adapter
4. `byedpi` как helper-only integration

## Внешние источники

- `olcrtc`: <https://github.com/openlibrecommunity/olcrtc> и <https://github.com/openlibrecommunity/olcrtc/blob/master/docs/about.md>
- `naiveproxy`: <https://github.com/klzgrad/naiveproxy/blob/master/README.md>
- `byedpi`: <https://github.com/hufrea/byedpi>
