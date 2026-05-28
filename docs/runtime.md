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
- `RuntimePlan.files` несет engine-specific runtime artifacts
- `RuntimeRegistry` остается allowlist для engine/helper registrations
- `MihomoEngineAdapter` остается default supported engine и production baseline
- `NaiveProxyEngineAdapter` держит transport в отдельном процессе и отдает Android VPN boundary текущему `clashCore` seam через локальный SOCKS bridge
- Android VPN start/stop path для `mihomo` проходит через `AccessControlService -> AndroidRuntimeAccessPolicy`
- access-control snapshot для `mihomo` подается в adapter через runtime composition boundary, а не читается внутри него напрямую
- pending `mihomo` core update применяется через transactional swap с rollback на предыдущий binary path
- pending `naiveproxy` update stage-ится тем же `.pending -> active -> .rollback` boundary в app data
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
- engine-specific files для runtime handoff
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
  - supported engine adapter
  - selection contract: `x-flclashm-runtime.engine=naiveproxy` + `x-flclashm-runtime.naiveproxy.proxy`
  - config contract: `x-flclashm-runtime.naiveproxy.extra` может передавать дополнительные upstream keys, но не может переопределять `listen` и `proxy`
  - update path: `setup.dart` вытягивает pinned stable release `v148.0.7778.96-5` из официальных plugin APK assets и пакует `libnaive.so` в bundled Flutter assets
  - activation path: adapter копирует bundled binary в app data, пишет `naiveproxy/config.json` из `RuntimePlan.files`, рестартует `naiveproxy` process только после записи нового runtime artifact и откатывает config/process к предыдущему состоянию, если bridge handoff не применился
  - bridge path: Android VPN/TUN остается на текущем `clashCore` seam, который потребляет локальный SOCKS listener `naiveproxy`
  - rollback path: failed pending activation восстанавливает предыдущий binary и сохраняет `.pending` для следующей попытки
  - limitation: quick-start/always-on snapshot очищается, потому что native cold-start engine selection для `naiveproxy` пока не поддержан
- `byedpi`
  - helper-only registration
  - unavailable до helper supervisor и явного attach contract

## Ограничения

- Provider hints не определяют runtime floor.
- `naiveproxy` listener path определяется клиентом, а не profile metadata.
- Unsupported runtime нельзя включить без registry change.
- Helper integration не владеет Android VPN/TUN lifecycle.
- Runtime orchestration не должна разъезжаться между UI/controller/service bridge.
- split tunneling/access-control orchestration не должна обходить `AccessControlService`.
