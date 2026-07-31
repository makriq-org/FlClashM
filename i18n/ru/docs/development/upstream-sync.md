# 🔄 Синхронизация с FlClashX

FlClashM построен на базе FlClashX. Продуктовая логика отделена, чтобы обновление базы оставалось **дешёвым**.

## 🧭 Принцип

- 📦 Продуктовая логика живёт в `lib/product/**`.
- 🚧 Код вне `lib/product/**` обращается к ней только через точки интеграции.

> 📎 Подробнее о границе base/product — в [архитектуре](architecture.md#-граница-между-базой-и-продуктом).

## 📝 Процесс обновления

1. ⬇️ Подтянуть FlClashX в отдельной ветке (обновление ведётся от `upstream/dev`).
2. 🧩 Разобрать конфликты в `lib/product/**`.
3. 🎛 Вне `lib/product/**` держать mounted-экраны в апстримных `lib/views/**`; product-логику вживлять только минимальными хуками.
   - Если base-файл реально импортирует `lib/product/**` — запись должна быть в `tool/product_touchpoints.json`.
   - Любой прочий base-дрейф должен быть объяснён в `tool/base_drift_allowlist.json`.
4. ✅ После слияния прогнать проверки:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
dart tool/check_base_drift.dart
```

Изменения апстрима, заметные пользователю, учитываются при выборе уровня повышения версии в ближайшем
релизе. Синк без такого эффекта отдельного релиза не требует; изменения runtime path
сначала выпускаются как `-preN` и проверяются на реальных Android ABI.

> 🤖 Полная процедура (fetch, `rerere`, drift-чекер, финальные гейты) описана в разделе «Процедура обновления апстрима» в [AGENTS.md](../../../../AGENTS.md).

---

> 🌍 Другие языки: [English](../../../en/docs/development/upstream-sync.md) · [中文](../../../zh/docs/development/upstream-sync.md) · [فارسی](../../../fa/docs/development/upstream-sync.md)
