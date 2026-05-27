# Architecture

## Цель

`FlClashM` развивается как `Android-only` клиент на обновляемой базе `FlClashX`.

Ключевая продуктовая цепочка в коде:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan -> EngineManager -> EngineAdapter`

На этапе `bootstrap/rebrand` эта цепочка собрана в `lib/product/**` без размазывания product policy по upstream-friendly base.

## Слои

### 1. FlClashX Base

- Flutter UI primitives
- upstream-friendly widgets/providers/models
- базовый clash/runtime path

### 2. Product Layer

- `AppBootstrap`
- `ProductPlatformProfile`
- `AndroidEntrypoint`
- `ProductProfilePipeline`
- `ProfileCompiler`
- `SecurityPolicy` / `AndroidSecurityPolicy`
- `EngineManager`
- Android platform policies (`AndroidForegroundNotificationPolicy`, `AndroidRuntimeAccessPolicy`, `AndroidUpdateBridge`)

### 3. Runtime Layer

- основной runtime: `mihomo`
- `EngineAdapter`
- `RuntimeRegistry` как allowlist и selection seam
- disabled registrations для `olcrtc`, `naiveproxy`, `byedpi`

### 4. Helper Layer

- `byedpi` только как helper registration, не как основной engine

### 5. Platform Layer

- Android VPN/service bridge
- permissions
- foreground service
- quick settings tile

## Текущий handoff

### `ProductProfilePipeline`

Ответственность:

- собрать product runtime pipeline в одном месте
- держать явные стадии compile/security/runtime-plan
- скрыть wiring между `GlobalState` и product contracts

Не должен:

- владеть lifecycle runtime
- читать/писать UI state напрямую

### `ProfileCompiler`

Ответственность:

- читать `RawProfile`
- применять только advisory provider hints
- собирать `CompiledProfilePatch` и metadata

Не должен:

- принимать client security decisions
- включать Android floor напрямую

### `SecurityPolicy`

Ответственность:

- применять client-enforced runtime floor
- применять тот же floor к прямым runtime updates
- выдавать `SecuredProfilePatch`
- отделять обязательные client rules от provider hints

Не должен:

- зависеть от provider headers как от обязательной policy
- ослаблять Android floor по данным подписки

### `EngineManager`

Ответственность:

- lifecycle engine/runtime
- orchestration adapters через `RuntimeRegistry`
- restart/update/cold-start boundaries
- compile-to-runtime handoff через явные callbacks `compile -> security -> runtimePlan`
- применять уже secured runtime updates перед adapter bridge

Не должен:

- содержать engine-specific bridge details
- принимать provider-specific product decisions

## Thin consumers

- `GlobalState` теперь только грузит `RawProfile`, строит локальный context для product pipeline и проецирует compiled metadata в UI-facing notifiers.
- `AppController` остается UI/runtime consumer: запускает manager, делегирует Android platform policies и не собирает runtime config сам.
- `AndroidEntrypoint` обрабатывает tile intents и вызывает product/runtime boundary.

## Android-only правила

- Android считается единственной поддерживаемой runtime platform.
- Android runtime policy задаётся клиентом, не подпиской.
- Security-critical поведение не определяется provider headers.
- Release continuity держится относительно `FlClash-my`.
