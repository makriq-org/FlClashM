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
- `mihomo` поддержан как production baseline
- `naiveproxy` интегрирован как отдельный engine adapter с pinned release/update/rollback path
- `olcrtc` и `byedpi` остаются disabled с guardrails и rollback/update notes

## Этап 4: platform shell consolidation

Сделано:

- foreground notification sync/title handoff локализован в `AndroidShellService`
- tile signaling/sync (`serviceReady`, profile change, mode, global-mode visibility) локализован в `AndroidShellService`
- task-back handoff локализован в `AndroidShellService`
- `AndroidEntrypoint` стал thin consumer и делегирует shell feedback/hooks в product service
- прямые `app/tile/vpn` shell вызовы убраны из `controller`, `providers/config`, `app_state_manager`, `AndroidManager`, `Application`
- `AndroidForegroundNotificationPolicy` очищена до pure policy без transport side effects

## Этап 5: mihomo runtime hardening

Сделано:

- на конец этапа 5 `mihomo` был зафиксирован как production baseline, пока `olcrtc`/`naiveproxy` оставались disabled
- `MihomoEngineAdapter` покрыт focused runtime tests, а не только общими `EngineManager` сценариями
- pending core update path переведен на transactional swap с rollback к предыдущему binary и сохранением `.pending` при неуспешной активации
- start/stop boundary усилен: listener/VPN rollback и cleanup теперь идут best-effort по обеим сторонам runtime boundary
- reattach/readStartTime и stop-failure state sync усилены в `EngineManager`, чтобы cold-start/runtime attach state был предсказуемее
- access-control handoff для `mihomo` теперь собирается на composition boundary, а не читается adapter напрямую из global state
- failed rollback после `start`/pending update больше не маскируется как обычный `false`: runtime boundary явно сигнализирует о broken cleanup

## Следующие шаги

### 1. Дальше по runtime

- hardening/telemetry для `naiveproxy`
- `olcrtc`
- `byedpi` как helper-only path

### 2. Дальше по базе

- Android smoke/regression на реальном устройстве после каждого нового engine adapter
- cleanup legacy runtime/UI wiring вокруг `GlobalState`/controller без сноса текущего baseline

## Риски

- в репозитории еще остается legacy desktop/base code, хотя продукт и release policy уже Android-only
- часть update/install UX все еще зависит от старого UI scaffolding (`loadingRun`, dialog helpers), хотя policy уже вынесена в product services
- часть Android lifecycle/runtime UX все еще опирается на legacy `GlobalState`/controller wiring, хотя `mihomo` baseline уже стабилизирован на runtime/product service boundary
- `naiveproxy` пока без always-on cold-start path: adapter сознательно очищает quick-start snapshot, пока engine selection/process handoff не будет перенесен в native cold-start flow
