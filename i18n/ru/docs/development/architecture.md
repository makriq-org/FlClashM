# 🏗 Архитектура

FlClashM построен на базе FlClashX. Продуктовая логика форка отделена от базы, чтобы обновления апстрима не ломали специфические возможности.

## 🔗 Главная цепочка

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| Стадия | Что делает |
|--------|-----------|
| **RawProfile** | Исходный профиль как есть |
| **ProfileCompiler** | Читает профиль, нормализует раздельное туннелирование, компилирует встроенные узлы |
| **SecurityPolicy** | Принудительно включает TUN на Android |
| **RuntimePlan** | Строит план запуска среды выполнения |
| **EngineManager** | Управляет жизненным циклом движка |
| **EngineAdapter** | Мост к `mihomo` |

## 🧱 Слои

1. 🎛 **База FlClashX** — UI, навигация, базовый runtime-путь.
2. 📦 **Продуктовый слой** (`lib/product/**`) — компиляция профиля, безопасность, обновления, fork-only страницы.
3. ⚙️ **Слой среды выполнения** — `mihomo` (baseline) и встроенные узлы `naiveproxy`, `olcrtc`, `byedpi`.
4. 📱 **Слой платформы** — Android VPN, foreground-служба, установщик, уведомления.

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
| `ProfileCompiler` | Чтение и нормализацию профиля |
| `SecurityPolicy` | Обязательное включение TUN на Android |
| `EngineManager` | Жизненный цикл движка |
| `BuiltInProxySupervisor` | Жизненный цикл встроенных узлов |
| `AppUpdateService` | Проверку, загрузку и установку обновлений приложения |
| `AppUpdateManifestVerifier` | Проверку подписи и контракта каталога обновлений |
| `AccessControlService` | Раздельное туннелирование |

---

> 🌍 Другие языки: [English](../../../en/docs/development/architecture.md) · [中文](../../../zh/docs/development/architecture.md) · [فارسی](../../../fa/docs/development/architecture.md)
