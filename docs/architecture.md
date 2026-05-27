# Architecture

## Цель

`FlClashM` развивается как `Android-only` клиент на обновляемой базе `FlClashX`.

Ключевая продуктовая цепочка:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan -> EngineManager -> EngineAdapter`

На текущем этапе уже выделен bootstrap seam, который нужен перед большой миграцией:

- `AppBootstrap` отвечает за старт приложения.
- `ProductPlatformProfile` определяет платформенный профиль приложения.
- `AndroidEntrypoint` держит Android quick actions, tile intents и foreground bootstrap вне `main.dart`.
- `AndroidSecurityPolicy` определяет Android runtime floor на стороне клиента.

## Слои

### 1. FlClashX Base

- Flutter UI primitives
- upstream-friendly widgets
- базовый clash/runtime path
- общие модели и часть providers

### 2. Product Layer

- `AppBootstrap`
- `ProductPlatformProfile`
- `AndroidEntrypoint`
- `AndroidSecurityPolicy`
- будущие `ProfileCompiler`, `EngineManager`, `UpdateService`

### 3. Runtime Layer

- основной runtime: `mihomo`
- будущие engine adapters: `olcrtc`, `naiveproxy`
- `RuntimeRegistry` как allowlist и selection seam

### 4. Helper Layer

- `byedpi` только как helper

### 5. Platform Layer

- Android VPN/service bridge
- permissions
- quick settings tile
- widgets
- foreground service

## Android-only правила

- Android считается единственной поддерживаемой runtime platform.
- Навигация на Android всегда идёт через compact/mobile surface, даже на широких экранах.
- Desktop shell не участвует в продуктовой архитектуре и release policy.
- Android runtime policy задаётся клиентом, не подпиской.

## Текущие seam-контракты

### `AppBootstrap`

Ответственность:

- инициализация Flutter/runtime
- preload core
- platform-specific boot hooks
- запуск `ProviderScope`

Не должен:

- содержать product policy
- содержать tile/widget бизнес-логику

### `ProductPlatformProfile`

Ответственность:

- определить, какой shell строить
- определить режим навигации
- скрыть platform branching от feature-кода

Не должен:

- хранить runtime state
- принимать security-решения

### `AndroidEntrypoint`

Ответственность:

- обработка Android quick actions
- синхронизация tile intents
- foreground notification title bootstrap

Не должен:

- компилировать профиль
- принимать security policy за профиль

### `AndroidSecurityPolicy`

Ответственность:

- enforce Android VPN/TUN floor
- централизовать Android runtime guardrails

Не должен:

- читать provider headers как источник обязательной security policy
- ослаблять client floor по данным подписки

## Текущий runtime seam

На этапе 2 orchestration идет через product layer:

- `EngineManager` владеет setup/start/stop/restart/update boundary
- `MihomoEngineAdapter` инкапсулирует текущий `clashCore`/Android bridge path
- `RuntimePlan` несет `RuntimeSelection`, а `RuntimeRegistry` решает какой engine/helper вообще допускается
- `state`, `controller` и `AndroidEntrypoint` выступают thin consumers этого seam
- app lifecycle consumers только pause/resume polling, без дублирования start/stop логики

Следующий шаг после этого seam:

- отделить Android platform policy от runtime orchestration
- подключать новые engine adapters через registry/descriptor path без переписывания bootstrap
- держать helper integrations вне engine lifecycle, пока для них не появится отдельный supervisor

## Android platform seam

На этапе 3 Android-specific policy вынесена в `lib/product/android/**`:

- `AndroidForegroundNotificationPolicy` собирает foreground title и держит policy для service/profile/server naming.
- для explicit proxy change foreground title обновляется из client-side selection, а не зависит от успешного `updateGroups()` round-trip
- `AndroidRuntimeAccessPolicy` централизует Android VPN start/stop access path и client-side merge для access-control.
- `AndroidUpdateBridge` держит Android app update/install boundary отдельно от view-кода и сам владеет external release open/install path.

Ожидаемые thin consumers:

- `controller` только синхронизирует runtime state и вызывает platform services
- `AndroidEntrypoint` только принимает tile intents и делегирует policy
- `plugins/vpn.dart` и `plugins/app.dart` остаются transport/shim слоем без product policy
