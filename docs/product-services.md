# Product Services

## Цель

На этапе 3 product orchestration для Android-specific behavior поднимается в `lib/product/services/**`, а platform seams остаются transport-only.

Текущие сервисы:

- `AppUpdateService`
- `AccessControlService`

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

## Границы

- provider headers не участвуют в updater policy
- provider headers не участвуют в Android access-control policy
- UI не должен напрямую знать о `AndroidUpdateBridge` и `AndroidRuntimeAccessPolicy`
- runtime adapter не должен собирать access-control rules сам
