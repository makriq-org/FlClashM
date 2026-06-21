# Синхронизация с FlClashX

FlClashM построен на базе FlClashX. Продуктовая логика отделена, чтобы обновление оставалось дешёвым.

## Принцип

- Продуктовая логика живёт в `lib/product/**`
- Код вне `lib/product/**` обращается к ней только через точки интеграции

## Процесс обновления

1. Подтянуть FlClashX в отдельной ветке
2. Разобрать конфликты в `lib/product/**`
3. Вне `lib/product/**` трогать только файлы из `tool/product_touchpoints.json`
4. После слияния прогнать проверки:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
```
