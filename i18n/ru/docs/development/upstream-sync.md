# Синхронизация с FlClashX

FlClashM обновляет базу из `upstream/dev`, сохраняя Android product layer и
контролируемый бюджет дрейфа. Синхронизация выполняется в отдельной worktree и
отдельной ветке от актуальной целевой ветки форка.

## Подготовка

```bash
git fetch upstream
git fetch origin
git status --short --branch
```

Remote `upstream` должен указывать на
`https://github.com/pluralplay/FlClashX.git`, а `origin` — на
`makriq-org/FlClashM`. Рабочее дерево перед merge должно быть чистым. Dart-пакет
форка называется `flclashx`, как в апстриме; массовая нормализация импортов после
merge не нужна и создаёт лишний drift.

## Merge

1. Создайте рабочую ветку от актуальной ветки FlClashM.
2. Выполните `git merge upstream/dev`.
3. Разрешайте конфликты по слоям: базовый UI ближе к апстриму, продуктовая
   политика в `lib/product/**`, Android/platform bridge — минимальный.
4. Не копируйте живые `lib/views/**` в product layer. Оставляйте узкий hook и
   регистрируйте его в `tool/product_touchpoints.json`.
5. Для неизбежного изменения base-пути добавляйте точное объяснение и корзину в
   `tool/base_drift_allowlist.json`; allowlist не заменяет архитектурное решение.

Для повторяющихся конфликтов включён `rerere`. Его можно прогреть на временной
ветке: один раз разрешить знакомые конфликты, проверить результат и удалить
ветку без добавления тренировочного merge в историю продукта.

## Проверка сразу после merge

Сначала проверяется новый base drift, пока источник каждого пути ещё понятен:

```bash
dart tool/check_base_drift.dart
```

Проверка вычисляет merge-base с `upstream/dev` и рассматривает изменения из
HEAD, индекса и рабочего дерева в `lib`, `android` и `core`. Если remote
недоступен в изолированной среде, передайте уже проверенный SHA:

```bash
dart tool/check_base_drift.dart --merge-base=<sha>
# или BASE_DRIFT_MERGE_BASE=<sha> dart tool/check_base_drift.dart
```

Новый путь нужно либо свести к зарегистрированной точке интеграции, либо явно
принять в бюджет с причиной. Не добавляйте широкие glob-записи только ради
зелёного CI.

## Финальные гейты

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product test/tool
dart tool/check_base_drift.dart
flutter analyze --fatal-infos lib/product test/product test/tool \
  tool/check_product_boundaries.dart tool/check_release_continuity.dart \
  tool/check_android_release_artifacts.dart \
  tool/check_android_release_signing.dart tool/write_release_metadata.dart \
  tool/write_app_update_manifest.dart tool/release_contract.dart setup.dart \
  lib/common/constant.dart lib/core_version.dart
```

Если merge затрагивает Android/runtime, дополнительно соберите arm64 APK и ABI,
которые изменились. Cold-start, always-on восстановление и процессы встроенных
узлов проверяются на реальных Android-устройствах перед выпуском.
