# Branding

Этот документ фиксирует, что именно в проекте считается брендом `FlClashM`, где это зашито и как это должно меняться дальше.

## Product brand

- Название продукта: `FlClashM`
- Android continuity package: `com.makriq.flclash`
- release repository: `makriq-org/FlClashM`
- Android artifact prefix: `FlClashM-android-*`

## Public identifiers

- deep link scheme: `flclashm://`
- generic import scheme, который клиент продолжает принимать: `clash://`
- provider customization headers: `flclashm-*`
- TV sync payload type: `flclashm_tv_sync`
- Android runtime method channels:
  - `com.makriq.flclash/service`
  - `com.makriq.flclash/device_id`
- Android widget/service action namespace: `com.makriq.flclash.*`

## Android runtime names

- Quick Settings tile service class: `FlClashMTileService`
- notification channel IDs:
  - `FlClashM`
  - `FlClashM_Subscription`
- persisted helper filenames:
  - `flclashm_always_on.json`
  - `flclashm_runtime_nodes.json`
  - `flclashm_vpn_active`
  - `flclashm_notif_title`
- documents provider root id: `flclashm`

## Migration notes

- Из старых `flclashx_*` Android helper files выполняется тихий перенос в новые `flclashm_*` имена при первом чтении.
- Старые notification channels `FlClashX*` удаляются при старте remote service.
- Старый payload type `flclashx_tv_sync` и старые product headers `flclashx-*` больше не считаются частью продуктового контракта.

## Non-public implementation detail

- Внутренний source namespace `com.follow.clashx*` в Android-коде пока остается частью унаследованной базы.
- Это не считается брендом продукта и не должно утекать в новые публичные контракты, документацию или интеграции.
