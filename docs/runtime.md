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
- `MihomoEngineAdapter` остается default supported engine и production baseline
- Android VPN start/stop path для `mihomo` проходит через `AccessControlService -> AndroidRuntimeAccessPolicy`
- access-control snapshot для `mihomo` подается в adapter через runtime composition boundary, а не читается внутри него напрямую
- pending `mihomo` core update применяется через transactional swap с rollback на предыдущий binary path
- `mihomo` start path считает foreground title best-effort и откатывает listener/VPN handoff при неуспешном старте
- `mihomo` stop path всегда пытается снять и listener, и VPN boundary, даже если одна из сторон падает
- `EngineManager` читает runtime start time у adapter и на fresh attach, и после stop failure boundary, чтобы reattach state не дрейфовал; при недоступном probe после успешного `start` он падает назад на локальный timestamp, а не роняет старт

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
- start-time sync для reattach/cold-start recovery boundary
- fail-fast guardrails для unsupported runtime selection

### `EngineAdapter`

Ответственность:

- конкретный bridge для runtime
- скрыть low-level детали `clashCore` / Android service path / cold-start persistence
- брать уже вычисленный access-control handoff из product service, а не собирать policy локально
- локально закрывать rollback/cleanup внутри runtime start/stop/update boundary, а не оставлять partial state наружу

## Baseline `mihomo`

На конец этапа 5 `mihomo` считается production baseline со следующими гарантиями:

- pending binary update либо целиком активируется, либо откатывается к предыдущему core с сохранением `.pending` для следующей попытки
- runtime reattach использует `readStartTime` самого adapter, а не только локальный `EngineManager` timestamp
- неуспешный `start` не должен оставлять висящий listener без VPN handoff
- если rollback/cleanup после failed `start` или failed pending update сам ломается, это поднимается наружу как ошибка, а не маскируется `false`
- `stop` и restart-prep не зависят от одного transport path: teardown/restart делаются best-effort по обеим сторонам boundary
- cold-start persistence и runtime attach boundary зафиксированы product/runtime tests, а не только общими manager tests

## Текущие регистрации

- `mihomo`
  - default engine
  - supported
  - hardened production baseline для Android lifecycle/recovery/update path
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
