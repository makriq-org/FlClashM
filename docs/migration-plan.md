# Migration Plan

## Фаза

`bootstrap/rebrand -> android-only`

## Уже сделано в этой итерации

- выделен `AppBootstrap`
- введён `ProductPlatformProfile`
- Android quick actions вынесены в `AndroidEntrypoint`
- Android security policy вынесена в `AndroidSecurityPolicy`
- Android навигация зафиксирована как compact/mobile-first surface
- provider-driven `flclashx-androidsecure` убран из обязательной runtime policy
- release/build pipeline сокращён до Android-only

## Ближайшие шаги

### 1. Выделить compile seam

- `RawProfile`
- `ProfileCompiler`
- `RuntimePlan`

### 2. Выделить runtime orchestration seam

- `EngineManager`
- `EngineAdapter`

### 3. Перенести Android-specific policy из общих state/controller мест

- VPN policy
- update/install path
- foreground notification policy

### 4. Подготовить continuity-safe updater path

- `applicationId = com.makriq.flclash`
- release signing continuity
- `versionCode` monotonic upgrade against public `FlClash-my`
- release channel `makriq-org/FlClashM`

## Риски

- часть runtime pipeline всё ещё живёт в `GlobalState` и `AppController`
- в репозитории ещё остаётся legacy desktop codebase, хотя release policy уже Android-only
- engine adapters пока ещё не оформлены как отдельные контракты

## Критерий завершения следующей фазы

Фаза считается завершённой, когда:

- профиль компилируется через отдельный product contract
- Android policy не размазана по UI/controller/state
- runtime adapters можно подключать без переписывания bootstrap
