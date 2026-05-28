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
- `ProductProviderAdvisory`
- `ProductProfilePipeline`
- `ProfileCompiler`
- `SecurityPolicy` / `AndroidSecurityPolicy`
- `EngineManager`
- `AppUpdateService`
- `AccessControlService`
- `AndroidShellService`

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
- Android platform policies/bridges (`AndroidForegroundNotificationPolicy`, `AndroidShellBridge`, `AndroidRuntimeAccessPolicy`, `AndroidUpdateBridge`)

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

### `AppUpdateService`

Ответственность:

- product policy для auto/manual update check
- result handling policy поверх Android update bridge
- отделить UI/controller от Android update transport details

Не должен:

- знать про widget state кроме переданного loading runner
- смешивать update policy с runtime orchestration

### `AccessControlService`

Ответственность:

- централизовать split tunneling/access-control session state
- держать handoff `UI state -> AccessControl -> Android runtime access path`
- держать package inventory/icon handoff для access UI внутри product/platform seam
- отдавать TUN authorization orchestration в platform seam без размазывания по controller/view/runtime adapter

Не должен:

- читать provider headers
- жить внутри Android transport bridge

### `AndroidShellService`

Ответственность:

- локализовать foreground notification sync/title handoff для Android runtime shell
- локализовать tile sync/signaling (`serviceReady`, profile change, mode, global-mode visibility)
- локализовать app-shell hooks (`tip`, shortcuts, move-task-to-back, exclude-from-recents, exit hook)
- держать `AndroidEntrypoint` тонким consumer'ом product/runtime событий

Не должен:

- содержать `MethodChannel`/plugin детали
- принимать runtime policy decisions вне shell orchestration

## Thin consumers

- `GlobalState` теперь только грузит `RawProfile`, строит локальный context для product pipeline и проецирует compiled metadata в UI-facing notifiers.
- `AppController` остается UI/runtime consumer: запускает manager, делегирует update/access/android-shell product services и применяет typed product advisory patch, не разбирая raw provider headers.
- `AndroidEntrypoint` принимает tile команды, но shell transport/hook details делегирует в `AndroidShellService`.
- `AboutView` использует `AppUpdateService`, а не `AndroidUpdateBridge` напрямую.
- `AccessView` и `MihomoEngineAdapter` используют `AccessControlService`, а не держат platform/runtime access policy локально.
- `providers/config`, `AppStateManager`, `AndroidManager` и `Application` остаются thin consumers и не знают про `app/tile/vpn` plugin детали.
- `providers/views/services` получают display/customization hints через `lib/product/subscription/**` и thin selectors, а не через raw `providerHeaders[...]`.

## Android-only правила

- Android считается единственной поддерживаемой runtime platform.
- Android runtime policy задаётся клиентом, не подпиской.
- Security-critical поведение не определяется provider headers.
- Release continuity держится относительно `FlClash-my`.
