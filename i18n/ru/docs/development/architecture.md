# Архитектура

FlClashM состоит из синхронизируемой базы FlClashX, продуктового слоя,
runtime-компонентов и Android-платформы. Граница нужна для дешёвого обновления
`upstream/dev`, а не для создания параллельного приложения внутри репозитория.

## Поток профиля

```text
RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan
           -> EngineManager -> EngineAdapter -> mihomo
```

| Стадия | Контракт |
| --- | --- |
| `RawProfile` | Исходный YAML и метаданные выбранного профиля без продуктовых преобразований |
| `ProfileCompiler` | Нормализация split tunneling, строгая проверка встроенных узлов и подмена их на локальные SOCKS5 |
| `SecurityPolicy` | Неослабляемая Android-политика, сейчас — обязательный TUN |
| `RuntimePlan` | Конфигурация `mihomo`, процессы встроенных узлов и их проверки как единый применяемый план |
| `EngineManager` | Транзакция подготовки, применения, замены и отката плана |
| `EngineAdapter` | Узкий контракт с реальным ядром и Android runtime |

Компиляция не запускает процессы. Она выдаёт декларативный план, который
`EngineManager` применяет через supervisor и адаптер. Благодаря этому ошибка
обязательной проверки останавливает новые процессы и сохраняет предыдущий
рабочий план.

## Слои

1. **FlClashX Base.** UI, навигация, модели и базовый путь `mihomo`. Живые
   апстримные экраны остаются в `lib/views/**`.
2. **Product Layer.** `lib/product/**`: компиляция профиля, policy, runtime
   orchestration, обновления, provider advisory и fork-only элементы.
3. **Runtime Layer.** `mihomo` как основной движок и процессы NaiveProxy,
   ByeDPI, OlcRTC, поставляемые для трёх Android ABI.
4. **Platform Layer.** Android VPN service, foreground notification, AIDL и
   MethodChannel-мосты, установщик APK и восстановление процесса.

## Граница base/product

Base-код вне `lib/product/**` импортирует продуктовый слой только через точки из
`tool/product_touchpoints.json`. Виджеты и фабрики `Widget` в product-слое
запрещены по умолчанию; каждое исключение требует записи в `allowedProductUi` с
конкретной причиной.

Неизбежные изменения Android, `core` или другого base-кода фиксируются в
`tool/base_drift_allowlist.json`. Запись в allowlist объясняет архитектурную
необходимость и корзину дрейфа, но не разрешает добавлять туда новую продуктовую
политику без обсуждения.

Границы проверяют две независимые команды:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_base_drift.dart
```

Base-drift вычисляется относительно merge-base с `upstream/dev` и учитывает
HEAD, индекс и рабочее дерево. Поэтому новый незарегистрированный путь виден ещё
до коммита.

## Владельцы жизненного цикла

| Компонент | Ответственность |
| --- | --- |
| `ProductProfilePipeline` | Последовательность compile и security без дублирования преобразований |
| `BuiltInProxySupervisor` | Подготовка артефактов, локальные порты и процессы узлов |
| `EngineManager` | Атомарная смена runtime plan и откат |
| Android service | Единственный владелец рабочих и probe-процессов, cold-start manifest и VPN |
| `AccessControlService` | Профильный приоритет пакетных правил и чтение фактически применённого снимка |
| `AppUpdateService` | Выбор ABI APK, проверка digest и передача установщику |
| `AppUpdateManifestVerifier` | Ed25519-подпись, канал и monotonic rollback-защита каталога |

Часть UI и lifecycle всё ещё связана через legacy `GlobalState` и controller.
Эти файлы считаются оркестрационными якорями: новые правила выносятся в product
services, а base получает готовое решение через узкий контракт.

## Добавление runtime-интеграции

До кода фиксируются четыре вещи:

1. слой и владелец процесса;
2. строгая схема входного профиля и локальный контракт с `mihomo`;
3. ограничения безопасности, включая адреса, порты, секреты и проверки сети;
4. воспроизводимое обновление и безопасный откат артефактов.

Новая интеграция считается завершённой после unit/contract-тестов и проверки
cold-start на всех поддерживаемых Android ABI; desktop-путь не должен становиться
неявной целью релиза.
