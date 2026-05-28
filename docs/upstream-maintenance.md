# Upstream Maintenance

## Цель

Дешевый update из `FlClashX` держится на простом правиле:

- product/runtime/platform логика живет в `lib/product/**`
- base-код вне `lib/product/**` может знать о product layer только через intentional touchpoints
- каждый touchpoint должен оставаться thin consumer, а не местом для новой product policy

## Source Of Truth

- `docs/architecture.md` фиксирует слои и контракты сервисов
- `tool/product_touchpoints.json` фиксирует allowlist base-файлов и канонические product-targets в `lib/product/**`
- `dart tool/check_product_boundaries.dart` валидирует этот allowlist

Guard сравнивает именно канонические product-targets, а не буквальный вид import/export URI. Поэтому package-import и relative-import считаются эквивалентными, если указывают в тот же файл внутри `lib/product/**`.

Если новый touchpoint действительно нужен:

1. сначала доказать, что логику нельзя удержать в `lib/product/**`
2. добавить файл в `tool/product_touchpoints.json`
3. кратко описать причину рядом в inventory и при необходимости обновить этот документ

## Allowed Patch Zones

Всегда разрешено:

- `lib/product/**`
- product-specific tooling и docs: `tool/check_product_boundaries.dart`, `tool/product_touchpoints.json`, `docs/upstream-maintenance.md`
- release/continuity guardrails, если меняется release contract

В base разрешены только allowlisted touchpoints из `tool/product_touchpoints.json`.

Их смысл по группам:

- `bootstrap-entrypoint`: `lib/main.dart`
- `global-runtime-wiring`: `lib/state.dart`
- `runtime-orchestration`: `lib/controller.dart`
- `platform-shell-bootstrap`: `lib/application.dart`, `lib/common/android.dart`, `lib/common/system.dart`, `lib/manager/android_manager.dart`, `lib/manager/app_state_manager.dart`, `lib/providers/config.dart`
- `subscription-and-platform-selectors`: `lib/providers/state.dart`, `lib/services/subscription_notification_service.dart`, `lib/views/profiles/profiles.dart`
- `ui-thin-consumers`: `lib/views/about.dart`, `lib/views/access.dart`

Что запрещено в base:

- новая security policy
- provider-driven runtime decisions
- engine-specific bridge logic
- Android update/install transport детали
- новые прямые импорты из `lib/product/**` вне inventory

## Cheap Update Flow

1. Подтянуть `FlClashX` в отдельной ветке обновления.
2. Сначала разбирать конфликты в `lib/product/**`.
3. Вне `lib/product/**` трогать только файлы из `tool/product_touchpoints.json`, если upstream update реально требует thin-consumer адаптацию.
4. Если конфликт требует новой product policy в base, это сигнал вынести change обратно в `lib/product/**`, а не плодить патч в base.
5. После merge/rebase прогнать:
   - `dart tool/check_product_boundaries.dart`
   - `dart tool/check_release_continuity.dart`
   - `flutter analyze --fatal-infos lib/product test/product tool/check_product_boundaries.dart tool/check_release_continuity.dart tool/check_android_release_artifacts.dart tool/write_release_metadata.dart tool/release_contract.dart setup.dart lib/common/constant.dart lib/core_version.dart`
   - `flutter test test/product`

Практический audit перед ревью:

- посмотреть diff вне product layer: `git diff --stat <upstream-ref> -- lib`
- отдельно проверить список product touchpoints: `dart tool/check_product_boundaries.dart`
- если touchpoint изменился по смыслу, обновить inventory в том же change

## Exit Result

Фаза `bootstrap/rebrand` считается завершенной, когда:

- product layer локализован в `lib/product/**`
- base/product граница проверяется tooling guard'ом
- upstream merge/rebase должен разбираться по текущим docs/contracts без скрытого знания старой patch-history

После этого репозиторий входит в режим `maintenance/cheap-upstream`.
