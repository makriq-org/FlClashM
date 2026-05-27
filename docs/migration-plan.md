# Migration Plan

## Фаза

`bootstrap/rebrand`

## Уже сделано

- новый Android-only bootstrap зафиксирован через `AppBootstrap`
- Android continuity guardrails и release continuity checks уже в tooling/tests
- compile seam выделен через `RawProfile`, `ProfileCompiler`, `ProductProfilePipeline`
- product-level `SecurityPolicy` добавлена как отдельный этап между compile и runtime plan
- advisory provider hints и client-enforced policy разведены по отдельным типам
- runtime seam выделен через `EngineManager`, `EngineAdapter`, `RuntimeRegistry`
- Android platform seam вынесен в `lib/product/android/**`
- provider-driven display/customization seam вынесен в `lib/product/subscription/**`
- `mihomo` поддержан как единственный enabled engine
- `olcrtc`, `naiveproxy`, `byedpi` остаются disabled с guardrails и rollback/update notes

## Следующие шаги

### 1. Перенос product services из legacy path

- updater
- split tunneling policy pieces
- оставшиеся Android-specific policy hooks

### 2. Стабилизация базы

- runtime start/stop regressions
- VPN behavior
- update/install flow

### 3. Интеграция runtime по одному

- `olcrtc`
- `naiveproxy`
- `byedpi` как helper-only path

## Риски

- в репозитории еще остается legacy desktop/base code, хотя продукт и release policy уже Android-only
- новые runtime пока есть только как registrations и guardrails, без production adapters
