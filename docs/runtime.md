# Runtime

## Цепочка

Runtime слой подготавливается через явную product chain:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan`

После этого lifecycle идет через:

`EngineManager -> EngineAdapter`

## Текущее состояние

- `RawProfile` живет в `lib/product/compile/raw_profile.dart`
- `ProductProfilePipeline` живет в `lib/product/compile/product_profile_pipeline.dart`
- `ProfileCompiler` выдает `CompiledProfilePatch`
- `AndroidSecurityPolicy` превращает его в `SecuredProfilePatch`
- `RuntimePlan` строится уже после security stage
- `EngineManager` вызывает стадии в явном порядке `compile -> security -> runtimePlan`
- direct `updateConfig` path тоже проходит через product security floor до adapter bridge
- `RuntimePlan.runtime` несет явный `RuntimeSelection`
- `RuntimeRegistry` остается allowlist для engine/helper registrations
- `MihomoEngineAdapter` остается default supported engine
- Android VPN start/stop path для `mihomo` проходит через `AccessControlService -> AndroidRuntimeAccessPolicy`

## Контракты

### `RawProfile`

Вход:

- профиль
- runtime config после локального script/evaluate path

Выход:

- нормализованный профиль
- `ProviderAdvisoryHints`
- `groupDescriptions`

### `ProfileCompiler`

Вход:

- `RawProfile`
- локальный patch config
- локальные override flags

Выход:

- `CompiledProfilePatch`
- advisory-merged metadata без client hardening

### `SecurityPolicy`

Вход:

- `CompiledProfilePatch`
- platform/client context

Выход:

- `SecuredProfilePatch`
- `RuntimeSecurityConstraints`

### `RuntimePlan`

Вход:

- `RawProfile`
- `SecuredProfilePatch`
- runtime patch config после tun-access resolution

Выход:

- полный config для engine setup
- `RuntimeSelection`
- metadata для UI handoff

### `EngineManager`

Ответственность:

- lifecycle engine/runtime
- orchestration adapters через `RuntimeRegistry`
- restart/update boundaries
- cold-start snapshot refresh
- fail-fast guardrails для unsupported runtime selection

### `EngineAdapter`

Ответственность:

- конкретный bridge для runtime
- скрыть low-level детали `clashCore` / Android service path / cold-start persistence
- брать уже вычисленный access-control handoff из product service, а не собирать policy локально

## Текущие регистрации

- `mihomo`
  - default engine
  - supported
  - update path: bundled Android core через `setup.dart` -> `libclash/android`
  - rollback path: bundled core + existing cold-start snapshot
- `olcrtc`
  - engine registration без включения
  - unavailable до pinned Android AAR, `gomobile` bridge и client-side compile path
- `naiveproxy`
  - engine registration без включения
  - unavailable до packaged release binary, `config.json` generation и Android SOCKS-to-VPN bridge
- `byedpi`
  - helper-only registration
  - unavailable до helper supervisor и явного attach contract

## Ограничения

- Provider hints не определяют runtime floor.
- Unsupported runtime нельзя включить без registry change.
- Helper integration не владеет Android VPN/TUN lifecycle.
- Runtime orchestration не должна разъезжаться между UI/controller/service bridge.
- split tunneling/access-control orchestration не должна обходить `AccessControlService`.
