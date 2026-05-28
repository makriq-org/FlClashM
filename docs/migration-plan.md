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
- `AppUpdateService` вынес updater policy над `AndroidUpdateBridge`
- `AccessControlService` вынес split tunneling/access-control policy над `AndroidRuntimeAccessPolicy`
- `AndroidShellService` вынес Android shell orchestration над `AndroidShellBridge`
- `mihomo` поддержан как единственный enabled engine
- `olcrtc`, `naiveproxy`, `byedpi` остаются disabled с guardrails и rollback/update notes

## Этап 4: platform shell consolidation

Сделано:

- foreground notification sync/title handoff локализован в `AndroidShellService`
- tile signaling/sync (`serviceReady`, profile change, mode, global-mode visibility) локализован в `AndroidShellService`
- task-back handoff локализован в `AndroidShellService`
- `AndroidEntrypoint` стал thin consumer и делегирует shell feedback/hooks в product service
- прямые `app/tile/vpn` shell вызовы убраны из `controller`, `providers/config`, `app_state_manager`, `AndroidManager`, `Application`
- `AndroidForegroundNotificationPolicy` очищена до pure policy без transport side effects

## Следующие шаги

### 1. Стабилизация базы

- runtime start/stop regressions
- VPN behavior
- update/install flow

### 2. Интеграция runtime по одному

- `olcrtc`
- `naiveproxy`
- `byedpi` как helper-only path

## Риски

- в репозитории еще остается legacy desktop/base code, хотя продукт и release policy уже Android-only
- часть update/install UX все еще зависит от старого UI scaffolding (`loadingRun`, dialog helpers), хотя policy уже вынесена в product services
- часть Android lifecycle/runtime UX все еще опирается на legacy `GlobalState`/controller wiring, хотя shell transport уже локализован
- новые runtime пока есть только как registrations и guardrails, без production adapters
