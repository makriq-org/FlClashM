# Идентификаторы бренда

Этот документ фиксирует, что именно считается брендом `FlClashM`, где это зашито
и как должно меняться.

## Продукт

- Название: `FlClashM`
- Android-пакет для непрерывности: `com.makriq.flclash`
- Репозиторий релизов: `makriq-org/FlClashM`
- Префикс артефактов Android: `FlClashM-android-*`

## Публичные идентификаторы

- Схема deep link: `flclashm://`
- Схема импорта профилей (принимается для совместимости): `clash://`
- Заголовки подсказок провайдера: `flclashm-*`
- Тип payload TV-синхронизации: `flclashm_tv_sync`
- Android runtime method channels:
  - `com.makriq.flclash/service`
  - `com.makriq.flclash/device_id`
- Пространство имён действий Android-виджета и сервиса: `com.makriq.flclash.*`

## Идентификаторы Android

- Класс плитки быстрых настроек: `FlClashMTileService`
- Идентификаторы каналов уведомлений:
  - `FlClashM`
  - `FlClashM_Subscription`
- Вспомогательные файлы:
  - `flclashm_always_on.json`
  - `flclashm_runtime_nodes.json`
  - `flclashm_vpn_active`
  - `flclashm_notif_title`
- Корневой идентификатор провайдера документов: `flclashm`

## Миграция из старых версий

- Старые вспомогательные файлы `flclashx_*` тихо переносятся в `flclashm_*`
  при первом чтении.
- Старые каналы уведомлений `FlClashX*` удаляются при запуске удалённого сервиса.
- Старый тип payload `flclashx_tv_sync` и заголовки `flclashx-*` больше не входят
  в продуктовый контракт.

## Внутреннее пространство имён

Внутренний source namespace `com.follow.clashx*` в Android-коде пока остаётся
частью унаследованной базы. Это не бренд продукта и не должно утекать в новые
публичные контракты, документацию или интеграции.
