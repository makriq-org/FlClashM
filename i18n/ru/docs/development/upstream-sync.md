# Синхронизация с FlClashX

FlClashM построен на базе FlClashX. Продуктовая логика отделена, чтобы обновление оставалось дешёвым.

## Принцип

- Продуктовая логика живёт в `lib/product/**`
- Код вне `lib/product/**` обращается к ней только через точки интеграции

## Процесс обновления

1. Подтянуть FlClashX в отдельной ветке
2. Перед ручным разбором конфликтов прогнать по конфликтующим Dart-файлам

```bash
git diff --name-only --diff-filter=U -- '*.dart' |
  xargs -r sed -i 's/package:flclashx\//package:flclashm\//g'
```

3. Разобрать конфликты в `lib/product/**`
4. Вне `lib/product/**` держать mounted-экраны в апстримных `lib/views/**`; product-логику вживлять только минимальными хуками. Если base-файл реально импортирует `lib/product/**`, запись должна быть в `tool/product_touchpoints.json`; любой прочий base-дрейф должен быть объяснен в `tool/base_drift_allowlist.json`
5. После слияния прогнать проверки:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
dart tool/check_base_drift.dart
```
