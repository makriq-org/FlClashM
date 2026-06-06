# Обновление базы из FlClashX

## Принцип

Дешёвое обновление из `FlClashX` держится на простом правиле:

- Продуктовая, runtime- и платформенная логика живёт в `lib/product/**`.
- Код вне `lib/product/**` может знать о продуктовом слое только через явно
  разрешённые точки интеграции.
- Каждая такая точка должна оставаться тонким потребителем, а не местом для
  новой продуктовой логики.

## Источник истины

- `docs/architecture.md` — слои и контракты сервисов.
- `tool/product_touchpoints.json` — список разрешённых файлов базы и их
  канонических целей в `lib/product/**`.
- `dart tool/check_product_boundaries.dart` — проверка этого списка.

Проверка сравнивает именно канонические цели, а не буквальный вид import-строк.
Package-импорт и относительный импорт считаются эквивалентными, если указывают
в тот же файл внутри `lib/product/**`.

Если новая точка интеграции действительно нужна:

1. Сначала доказать, что логику нельзя удержать в `lib/product/**`.
2. Добавить файл в `tool/product_touchpoints.json`.
3. Кратко описать причину рядом в списке и при необходимости обновить этот документ.

## Разрешённые зоны изменений

Всегда разрешено:

- `lib/product/**`
- Продуктовый инструментарий и документация: `tool/check_product_boundaries.dart`,
  `tool/product_touchpoints.json`, `docs/upstream-maintenance.md`
- Защиты непрерывности релизов при изменении контракта релизов

В базе разрешены только точки интеграции из `tool/product_touchpoints.json`.
Их смысл по группам:

- `bootstrap-entrypoint`: `lib/main.dart`
- `global-runtime-wiring`: `lib/state.dart`
- `runtime-orchestration`: `lib/controller.dart`
- `platform-shell-bootstrap`: `lib/application.dart`, `lib/common/android.dart`,
  `lib/common/system.dart`, `lib/manager/android_manager.dart`,
  `lib/manager/app_state_manager.dart`, `lib/providers/config.dart`
- `subscription-and-platform-selectors`: `lib/providers/state.dart`,
  `lib/services/subscription_notification_service.dart`,
  `lib/views/profiles/profiles.dart`
- `ui-thin-consumers`: `lib/views/about.dart`, `lib/views/access.dart`

Что запрещено в базе:

- новая политика безопасности
- решения среды выполнения, зависящие от провайдера
- логика моста конкретного движка
- детали транспорта обновления/установки Android
- новые прямые импорты из `lib/product/**` вне списка

## Процесс обновления

1. Подтянуть `FlClashX` в отдельной ветке обновления.
2. Сначала разбирать конфликты в `lib/product/**`.
3. Вне `lib/product/**` трогать только файлы из `tool/product_touchpoints.json`,
   если обновление upstream действительно требует адаптации тонкого потребителя.
4. Если конфликт требует новой продуктовой логики в базе, это сигнал вынести
   изменение обратно в `lib/product/**`, а не добавлять патч в базу.
5. После слияния или перебазирования прогнать:
   - `dart tool/check_product_boundaries.dart`
   - `dart tool/check_release_continuity.dart`
   - `flutter analyze --fatal-infos lib/product test/product tool/check_product_boundaries.dart tool/check_release_continuity.dart tool/check_android_release_artifacts.dart tool/write_release_metadata.dart tool/release_contract.dart setup.dart lib/common/constant.dart lib/core_version.dart`
   - `flutter test test/product`

Быстрый аудит перед ревью:

- Посмотреть изменения вне продуктового слоя: `git diff --stat <upstream-ref> -- lib`
- Отдельно проверить список точек интеграции: `dart tool/check_product_boundaries.dart`
- Если смысл точки интеграции изменился, обновить список в том же коммите.
