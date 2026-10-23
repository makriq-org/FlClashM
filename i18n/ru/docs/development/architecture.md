# 🏗 Архитектура

FlClashM построен на базе FlClashX. Продуктовая логика форка отделена от базы, чтобы обновления апстрима не ломали специфические возможности.

## 🔗 Главная цепочка

Runtime path принадлежит единому Go backend (`core/backend/**`), который работает в Android-процессе `:remote` независимо от Flutter:

```
RawProfile + настройки + capabilities → Go Compiler + SecurityPolicy
→ неизменяемый RuntimePlan → внутренний RuntimeCoordinator → EngineAdapter
```

| Стадия | Что делает |
|--------|-----------|
| **RawProfile** | Исходный профиль как есть, хранится в Go-каталоге вместе с настройками |
| **Go Compiler** | Читает профиль, нормализует раздельное туннелирование, компилирует встроенные узлы |
| **SecurityPolicy** | Защищает mixed port, ограничивает global mode, исключает приложение из VPN и фиксирует правила split tunneling |
| **RuntimePlan** | Неизменяемый проверенный план с поколением и digest; клиент не передаёт свой план |
| **RuntimeCoordinator** | Единственный владелец состояния runtime: очередь эффектов, отмена, откат, восстановление без UI |
| **EngineAdapter / NodeAdapter** | Исполнение `mihomo` и отдельных процессов встроенных узлов |

Подробный контракт API, состояний, хранения и миграции — в [описании Go backend](go-backend/architecture.md).

## 🧱 Слои

1. 🎛 **База FlClashX** — UI, навигация, пользовательские действия; состояние runtime получает из снимков и событий Go API v1.
2. 🧠 **Go backend** (`core/backend/**`) — профили, подписки, настройки, компиляция, SecurityPolicy, исполнение и восстановление.
3. ⚙️ **Слой среды выполнения** — `mihomo` и отдельные процессы встроенных узлов `naiveproxy`, `olcrtc`, `byedpi`, `stormdns`.
4. 📱 **Слой платформы** — Android-процесс `:remote`, разрешения, VPN/TUN, foreground-служба, события ОС; `:validator` изолирует разбор профиля.
5. 📦 **Продуктовый слой** (`lib/product/**`) — тонкий клиент backend, обновления APK, диагностика, fork-only страницы.

## 🚧 Граница между базой и продуктом

Базовый код вне `lib/product/**` обращается к продуктовому слою **только через точки интеграции** из `tool/product_touchpoints.json`.

- Живые `lib/views/**` **не дублируются** в `lib/product/**`: в base остаются апстримные экраны с минимальными хуками.
- Классы виджетов и фабрики `Widget` в `lib/product/**` запрещены по умолчанию; собственные элементы FlClashM должны быть явно внесены в `allowedProductUi` из `tool/product_touchpoints.json` с указанием причины.

Проверяется гейтом:

```bash
dart tool/check_product_boundaries.dart
```

> 📎 Как это соотносится с обновлением апстрима — в [синхронизации с FlClashX](upstream-sync.md). Правила для контрибьюторов — в [AGENTS.md](../../../../AGENTS.md).

## 🧩 Основные сервисы

| Сервис | Отвечает за |
|--------|-------------|
| Go `Compiler` + `SecurityPolicy` | Чтение, нормализацию и проверку профиля перед исполнением |
| Go `RuntimeCoordinator` | Жизненный цикл движка и встроенных узлов, откат и восстановление |
| `BackendClient` (Dart) | Команды UI и чтение снимков Go backend |
| `AppUpdateService` | Проверку, загрузку и установку обновлений приложения |
| `AppUpdateManifestVerifier` | Проверку подписи и контракта каталога обновлений |
| `AccessControlService` | Редактор раздельного туннелирования в UI |

## Единый Go backend

Контракт, миграция данных и этапы переноса: [Go backend](go-backend/architecture.md),
[инвентаризация сценариев](go-backend/inventory.md),
[журнал стабилизации](go-backend/stabilization.md). Прежние Dart `ProfileCompiler`,
`EngineManager`, `BuiltInProxySupervisor` и Kotlin process manager удалены;
описание выше отражает текущий runtime path.

---

> 🌍 Другие языки: [English](../../../en/docs/development/architecture.md) · [中文](../../../zh/docs/development/architecture.md) · [فارسی](../../../fa/docs/development/architecture.md)
