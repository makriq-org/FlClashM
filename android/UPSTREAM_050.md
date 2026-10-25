# Android host для интерфейса 0.5.0

Источник: `upstream/0.5.0-dev`,
`5b38c0c7dfba726b8335407d0df5e6205e2d9bfa`.

## Flutter transport

Namespace каналов — **`com.makriq.flclash`**, независимо от Kotlin package и
суффикса debug applicationId. JNI/Go bridge, `:remote` и `:validator` сохранены.

- `/service.invokeAction(String)` возвращает `String` JSON `ActionResult`.
- `/core.invokeMethod(String)` (также `invokeAction`) возвращает `Uint8List`
  UTF-8 **того же `ActionResult`**, а не upstream `CoreMethodResponse`.
- Оба принимают прежний Action `{id,method,data}`. `data` передаётся без
  преобразований: JSON string, object, array или bool разбирает Go.
- Go API v1 передаётся как `{id:operationId,method:"backend",data:request}`,
  где request — `{apiVersion:1,operationId,method,params}`. Ошибки, снимки,
  квитанции и blob API не изменены.
- `/service.init()` возвращает `""`; события `event` содержат строку прежнего
  envelope, `crash` — строку причины потери IPC.
- `/service.init({eventEncoding:"utf8"})` включает `Uint8List` для `event`.
  Схема envelope остаётся прежней. Это явное согласование, старые клиенты
  продолжают получать строки.
- `probe`, `outboundIp`, `serviceCheck`, `watchRoute`, `getConnectionCount`,
  `getMemoryStats`, `encodeShareLinks`, `decodeShareLinks`, `validateFilters`,
  `validateProxies`, `getProxiesData`, `setHostActive` разрешены вместе с
  прежними диагностическими helpers. `validateProxies` из Go обращается к
  `:validator`. Прямые runtime setters запрещены.
- Lifecycle и запись данных идут через Go API v1. Upstream SharedState не
  становится источником данных: `syncState` только перечитывает проекцию.

Core channel использует background task queue, dispatch — `Dispatchers.Default`.
Сериализация ответов и событий выполняется вне main; только отправка
готового Flutter-сообщения выполняется на main. Стандартный ответ обработчика
MethodChannel подтверждает обработку события: при остановленном Dart isolate
остаётся одно сообщение в полёте, без накопления platform messages.
Очереди событий ограничены
256 ожидающими и одной доставляемой записью на каждой стороне Binder. При
переполнении удаляется старейшее наблюдение; пропуск seq требует снимка через
BackendClient. Ответы команд идут отдельно, сохраняя chunking/ACK. Новая задача
отправки не создаётся для каждого события. Stop не ждёт обработки очереди событий
перед передачей команды в Go. Уже начатый Binder stream сохраняет прежний ACK timeout.

## Платформенные каналы

- `/app` поддерживает методы прежнего `app`, включая installer и OEM/autostart.
  `getPackageIcon` возвращает абсолютный путь PNG 128×128 в кэше для FileImage;
  старый `app` сохраняет base64. Кэш ограничен и учитывает версию пакета.
- `/app` также предоставляет `getAndroidId`, `getLastExitInfo`, `openAppSettings`,
  `isInstalledAppsPermissionGranted`, `requestInstalledAppsPermission`,
  `isLocalNetworkPermissionGranted`, `requestLocalNetworkPermission`.
  Последние два проверяют/запрашивают разрешение ОС Android 17+, без preferences.
  Отказ в локальной сети не должен запрещать сам VPN: UI показывает реальный
  результат разрешения и продолжает обычную подготовку VPN. Существующий
  `/service.requestVpnPermission` запрашивает также LAN из видимой Activity,
  затем возвращает именно результат VPN consent, независимо от отказа LAN.
- `/app` отправляет `packagesChanged(null)`, `floatingImeChanged(bool)` для
  плавающей клавиатуры Android TV и `exit(null)`. Старый канал сохраняет `exit`.
- `/battery.requestIgnoreOptimizations` завершается при возвращении из системных
  настроек. `/battery/optimization` — EventChannel: текущее bool при подписке и
  изменения. Xiaomi использует политику PowerKeeper «Без ограничений».
- `/tile` совместим с прежним `tile`. Native tile, widgets и shortcuts отправляют
  команды Go напрямую. `START`/`STOP`/`CHANGE` сохранены, `TOGGLE` — alias `CHANGE`.

High refresh rate выбирает самый быстрый режим текущего разрешения только для
видимой Activity. Ссылки install-config обрабатывает app_links без второго
Flutter route; схемы clashmeta/clashx добавлены с точным host install-config.

## Эквиваленты upstream, сохранённые в нашей архитектуре

Foreground/VPN lifetime, явный Stop, headless cold start и reconnect уже реализованы
через RuntimeCoordinator и Android host. Network/DNS/screen/Doze наблюдения уже
передаются Go; их политика не перенесена в новый Kotlin lifecycle. Транспорты,
диагностика, установщик APK, запрет backup и ограниченные FileProvider/deep-link
пути сохранены. `routeChanged` обновляет уведомление через существующее объединение
сигналов; DNS/log/request не вызывают тяжёлое перечитывание представления.

Kotlin unit tests проверяют очереди, отмену, permissions callbacks, display modes,
allowlist helpers/запрет runtime setters и ключи кэша. Instrumentation проверяет
оба формата иконок, Battery EventChannel, настоящий v1 snapshot через оба
transport-канала и завершение Stop при неподтверждённом событии Flutter. Существующие AndroidRuntimeE2eTest сохраняют проверки большого
chunked профиля, validator, Stop и восстановления без Flutter.

## Проверка совместимости

Kotlin unit-тесты очереди событий проверяют продолжение после ошибки отдельной
доставки и сохранение отмены coroutine. Ошибка наблюдения не должна отключать
последующие события; отмена при остановке host должна завершать доставку.

Android 17 LAN consent, MIUI PowerKeeper и TV floating IME требуют устройства
соответствующего типа. Эмулятор Android 16 проверяет транспорт и общий lifecycle;
перед выпуском нужны проверки на реальных Android ABI.

## Учёт расхождений с апстримом

`tool/base_drift_allowlist.json` закрепляет источник через `upstreamImport.commit`.
Следующие файлы побайтно совпадают с указанным выше SHA и проверяются guard как
точные копии апстрима, без отдельных записей в `allowedBaseDrift`:

- `android/app/src/main/kotlin/com/follow/clashx/DisplayModes.kt`
- `android/app/src/main/kotlin/com/follow/clashx/HighRefreshRate.kt`
- `android/app/src/test/kotlin/com/follow/clashx/DisplayModesTest.kt`
- `android/app/src/main/res/drawable/ic_shortcut_start.xml`
- `android/app/src/main/res/drawable/ic_shortcut_stop.xml`
- `android/app/src/main/res/drawable/ic_shortcut_toggle.xml`

Локальные адаптации Android host и их тесты учитываются отдельно в
`allowedBaseDrift` с причиной. При изменении точной копии она также требует
регистрации как локальная адаптация. Проверку выполняет
`dart tool/check_base_drift.dart` относительно закреплённого источника.
