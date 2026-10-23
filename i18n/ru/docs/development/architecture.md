# Архитектура

FlClashM сохраняет интерфейс FlClashX и выносит управление подключением в Go.

```text
Исходный профиль + настройки + возможности платформы
  → Go Compiler + SecurityPolicy
  → неизменяемый RuntimePlan
  → RuntimeCoordinator
  → mihomo / внешние процессы / Android VPN
```

## Слои и ответственность

| Слой | Ответственность |
|---|---|
| Flutter, `lib/**` | Интерфейс, навигация, черновики редакторов, команды и снимки backend |
| Product UI, `lib/product/**` | Клиент Go API, страницы форка, обновление APK и диагностика |
| Go backend, `core/backend/**` | Профили, подписки, настройки, компиляция, запуск и восстановление |
| Адаптеры, `core/backend_host.go`, `core/backend/transport/**` | mihomo и отдельные процессы NaiveProxy, OlcRTC, ByeDPI, StormDNS |
| Android host, `android/service/**` | Разрешения, foreground-служба, VPN/TUN, DNS и события ОС |

`RuntimeCoordinator` — единственный владелец изменяемого состояния подключения.
Flutter и Android `StateHub` показывают его снимки. Они не выбирают стратегии,
не планируют восстановление и не управляют runtime своими таймерами.
Backend работает в процессе `:remote` независимо от Flutter. Процесс `:validator`
изолирует полную проверку конфигурации mihomo.

Контракты API, состояния и данных — в [справочнике Go backend](go-backend/architecture.md).
Жизненный цикл и внешние узлы — в [описании runtime](runtime.md).

## Граница между базой и продуктом

- Базовый Dart-код обращается к `lib/product/**` через записи в
  `tool/product_touchpoints.json`.
- Экраны `lib/views/**` остаются в базе с минимальными хуками. Страницы только
  для форка размещаются в `lib/product/pages/**`.
- Виджеты product-слоя регистрируются с причиной в `allowedProductUi`.
- Остальные изменения base-файлов учитываются в `tool/base_drift_allowlist.json`.

Границы проверяют `dart tool/check_product_boundaries.dart` и
`dart tool/check_base_drift.dart`. Порядок обновления базы описан в
[синхронизации с апстримом](upstream-sync.md).
