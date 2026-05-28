# Product Services

## Цель

На этапе 3 product orchestration для Android-specific behavior поднимается в `lib/product/services/**`, а platform seams остаются transport-only.

Текущие сервисы:

- `AppUpdateService`
- `AccessControlService`
- `AndroidShellService`

## `AppUpdateService`

Контракт:

- владеет policy для `auto-check`, `manual-check` и result handling
- решает, когда update path вообще выполняется
- делегирует transport-действия в `AndroidUpdateBridge`

`AndroidUpdateBridge` после этого отвечает только за:

- `checkForAppUpdate`
- prompt/download dialog
- explicit error dialog
- open latest release page
- package install handoff

Thin consumers:

- `AppController.autoCheckUpdate`
- `AboutView`

## `AccessControlService`

Контракт:

- централизует editable session state для split tunneling/access-control
- переводит UI state <-> `VpnProps.accessControl`
- управляет package inventory/icon handoff для access UI
- делегирует runtime access orchestration в `AndroidRuntimeAccessPolicy`

`AndroidRuntimeAccessPolicy` после этого отвечает только за:

- merge Android VPN options с уже вычисленным `AccessControl`
- package inventory/icon transport для access-control UI
- start/stop VPN bridge
- TUN authorization / restart resolution

Thin consumers:

- `AccessView`
- `AppController._resolveTunAccess`
- `MihomoEngineAdapter.start/stop`
- `NaiveProxyEngineAdapter.start/stop`

## Границы

- provider headers не участвуют в updater policy
- provider headers не участвуют в Android access-control policy
- UI не должен напрямую знать о `AndroidUpdateBridge` и `AndroidRuntimeAccessPolicy`
- runtime adapter не должен собирать access-control rules сам

## `AndroidShellService`

Контракт:

- централизует Android shell orchestration для foreground notification, tile и app-shell hooks
- строит foreground title через `AndroidForegroundNotificationPolicy` и отдает transport в `AndroidShellBridge`
- владеет tile/service hooks: `serviceReady`, profile-change sync, mode sync, global-mode sync
- владеет app-shell hooks: `tip`, shortcuts, `moveTaskToBack`, `excludeFromRecents`, exit hook

`AndroidShellBridge` после этого отвечает только за:

- `app` plugin handoff (`tip`, shortcuts, move-task-to-back, exclude-from-recents, exit callback)
- `tile` plugin handoff (`serviceReady`, `updateTile`, `updateMode`, `updateGlobalModeEnabled`)
- `vpn` notification handoff (`updateNotification`)

Thin consumers:

- `AndroidEntrypoint`
- `AppController`
- `providers/config`
- `AppStateManager`
- `AndroidManager`
- `Application`
- `MihomoEngineAdapter`
- `NaiveProxyEngineAdapter`

Границы:

- `AndroidEntrypoint` не должен знать про `app?/tile?/vpn?` plugin детали
- UI/providers/managers не должны напрямую вызывать Android shell plugins
- `AndroidForegroundNotificationPolicy` остается pure policy без transport side effects
- profile-change tile refresh должен идти после persistence, потому что native side читает сохраненный `flutter.config`
