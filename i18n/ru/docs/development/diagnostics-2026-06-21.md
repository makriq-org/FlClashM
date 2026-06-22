# Диагностика FlClashM на 2026-06-21

## Объём проверки

- Правки в код не вносились.
- Проверка выполнена по живому дереву репозитория, истории Git и сравнению с `upstream`.
- Локально недоступны `flutter` и `dart`, поэтому прогон Flutter/Dart-тестов и сборки из этого окружения не выполнен.

## Краткий вывод

Проблема не одна.

1. Режим `maintenance/cheap-upstream` фактически нарушен: локальная ветка сильно ушла от `FlClashX` по UI и базовому runtime wiring.
2. Встроенная проверка IP внутри самого приложения на Android по текущему коду не может быть надёжным индикатором работы VPN, потому что приложение принудительно исключает собственный пакет из туннеля.
3. Поддержка split tunneling через профиль в product pipeline есть, но UI для profile-managed режима неполный и плохо объясняет, что именно применено.
4. Путь запуска и применения профиля стал многошаговым, с длинными таймаутами и без использования уже существующего атомарного `quickStart`, поэтому любая подвисшая граница превращается в долгий пользовательский wait.

Ниже детали.

## 1. Апстрим подтянут не как "чистая новая база", а как база плюс большой локальный дрейф

### Что подтверждено

- Текущий `main` не отстаёт от `upstream/dev`; он уже содержит его и уходит дальше локальными коммитами.
- По состоянию репозитория `main...upstream/dev = 89 0`.
- Последний явный sync: `406381b merge: sync FlClashX dev through v0.4.0-pre.17`.
- После него в локальной ветке накопились собственные изменения UI и runtime.

### Почему это важно

Жалоба "интерфейс у нас старый, а в актуальном APK апстрима он другой" по коду выглядит не как простой недотянутый fetch/merge. Проблема глубже: локальная ветка поверх апстрима меняет слишком много базовых файлов, поэтому идентичность с апстримным APK больше не гарантируется.

### Прямые признаки в дереве

- В diff `upstream/dev..main` изменено `197` файлов под `lib/`.
- Из них `136` лежат вне `lib/product/**` и вне разрешённых touchpoints из `tool/product_touchpoints.json`.
- Сильно затронуты `lib/views/dashboard/**`, `lib/views/profiles/**`, `lib/views/config/**`, `lib/widgets/**`, `lib/clash/**`, `lib/models/**`, `lib/common/**`.

### Конкретные места

- Разрешённые touchpoints перечислены в [tool/product_touchpoints.json](/home/max/Projects/FlClashM/tool/product_touchpoints.json:1).
- Фактический UI drift виден хотя бы по [lib/views/dashboard/widgets/hero_connect.dart](/home/max/Projects/FlClashM/lib/views/dashboard/widgets/hero_connect.dart:1), [lib/views/dashboard/dashboard.dart](/home/max/Projects/FlClashM/lib/views/dashboard/dashboard.dart:1), [lib/views/profiles/profiles.dart](/home/max/Projects/FlClashM/lib/views/profiles/profiles.dart:1), [lib/views/config/general.dart](/home/max/Projects/FlClashM/lib/views/config/general.dart:1).

### Вывод

Причина расхождения UI с апстримом сейчас не в том, что "апстрим не подтянули". Причина в том, что после синка база была существенно переизменена локально, причём далеко за пределами заявленного `cheap-upstream` контракта.

## 2. Наблюдение "VPN поднят, но IP внутри клиента не меняется" подтверждается кодом как ложный диагностический сигнал

### Что подтверждено

На Android клиент принудительно выводит собственный пакет из VPN access control.

Это сделано прямо в [lib/product/android/android_runtime_access_policy.dart](/home/max/Projects/FlClashM/lib/product/android/android_runtime_access_policy.dart:92):

- если access control выключен, код всё равно включает `rejectSelected` и добавляет в исключения сам пакет приложения;
- если access control в режиме include, пакет приложения вырезается из `acceptList`;
- если access control в режиме exclude, пакет приложения насильно добавляется в `rejectList`.

Это поведение закреплено тестом в [test/product/android/android_runtime_access_policy_test.dart](/home/max/Projects/FlClashM/test/product/android/android_runtime_access_policy_test.dart:26).

### Почему это ломает встроенную проверку IP

Встроенный HTTP path для проверки IP на Android намеренно идёт как `DIRECT`, рассчитывая, что трафик будет пойман TUN:

- см. [lib/common/http.dart](/home/max/Projects/FlClashM/lib/common/http.dart:32)
- при `Platform.isAndroid` `handleFindProxy()` возвращает `DIRECT`: [lib/common/http.dart](/home/max/Projects/FlClashM/lib/common/http.dart:45)
- сама проверка IP использует именно этот путь: [lib/common/request.dart](/home/max/Projects/FlClashM/lib/common/request.dart:183)

Но сам пакет приложения уже исключён из VPN, поэтому встроенный check IP на Android логически видит внешний адрес обычной сети, а не туннеля.

### Практический смысл

Если пользователь оценивает работоспособность VPN по IP, который показывает сам FlClashM, текущий код даёт систематически неверную картину:

- туннель может быть поднят;
- трафик сторонних приложений может идти через VPN;
- сам FlClashM всё равно будет ходить напрямую.

### Ограничение

Это объясняет именно наблюдение внутри клиента. Без логов с устройства и без проверки трафика внешнего приложения нельзя по одному этому месту доказать, что весь device traffic тоже уходит в `DIRECT`.

## 3. Split tunneling через профиль в product pipeline есть, но UX и wiring оставляют дыры

### Что подтверждено по цепочке

Product pipeline для profile-driven split tunneling существует:

1. Компилятор профиля вызывает `resolveAndroidProfileSplitTunneling(...)`: [lib/product/compile/profile_compiler.dart](/home/max/Projects/FlClashM/lib/product/compile/profile_compiler.dart:112)
2. Там читаются `tun.include-package`, `tun.exclude-package`, `*-file`, `*-url`: [lib/product/compile/profile_split_tunneling.dart](/home/max/Projects/FlClashM/lib/product/compile/profile_split_tunneling.dart:136)
3. Из них строится `AccessControl`: [lib/product/compile/profile_split_tunneling.dart](/home/max/Projects/FlClashM/lib/product/compile/profile_split_tunneling.dart:281)
4. Этот `profileAccessControl` кладётся в `RuntimePlan`: [lib/product/compile/profile_compiler.dart](/home/max/Projects/FlClashM/lib/product/compile/profile_compiler.dart:177)
5. Дальше он сохраняется в `GlobalState.activeProfileAccessControlNotifier`: [lib/state.dart](/home/max/Projects/FlClashM/lib/state.dart:387)
6. И используется при старте VPN через `resolveVpnAccessControl(...)`: [lib/product/runtime/mihomo_engine_adapter.dart](/home/max/Projects/FlClashM/lib/product/runtime/mihomo_engine_adapter.dart:347)

То есть по статике кода сама цепочка "профиль -> runtime plan -> Android VPN options" присутствует.

### Почему пользователь может не видеть результат в UI

В `AccessView` profile-managed режим специально блокирует редактирование и одновременно убирает единственный явный summary по выбранным приложениям:

- профильный режим определяется через `activeProfileAccessControl`: [lib/views/access.dart](/home/max/Projects/FlClashM/lib/views/access.dart:53)
- при `_profileManaged` UI только показывает lock-иконку: [lib/views/access.dart](/home/max/Projects/FlClashM/lib/views/access.dart:147)
- счётчик выбранных пакетов скрывается условием `if (!_profileManaged && ...)`: [lib/views/access.dart](/home/max/Projects/FlClashM/lib/views/access.dart:264)

Итог:

- в ручном режиме есть хотя бы явный count;
- в profile-managed режиме count убран;
- пользователь должен сам визуально искать отмеченные приложения в длинном списке;
- если нужное приложение вне текущего фильтра или не попало в видимую часть списка, создаётся ощущение, что ничего не применилось.

### Дополнительный риск в wiring

В коде есть отдельная функция восстановления Android split tunneling полей из исходного YAML:

- [lib/product/compile/profile_split_tunneling.dart](/home/max/Projects/FlClashM/lib/product/compile/profile_split_tunneling.dart:28)

Но по дереву она нигде не вызывается.

Это выглядит как незавершённый safeguard на случай, когда часть полей `tun.*package*` теряется после промежуточной обработки профиля. По статике я не могу доказать, что это уже бьёт текущий сценарий, но это явно подозрительный незавершённый кусок интеграции.

### Вывод

По коду split tunneling через профиль не выглядит "полностью отсутствующим". Скорее проблема двойная:

- UX не показывает профильное состояние достаточно явно;
- интеграция имеет признаки незавершённости и требует live-проверки на устройстве с конкретным YAML.

## 4. Текущий старт и apply-путь сильно усложнён и сам по себе провоцирует долгие ожидания

### Что подтверждено

Сейчас запуск идёт так:

1. `_updateStatus(true)` сначала делает `_setupClashConfig(...)`: [lib/controller.dart](/home/max/Projects/FlClashM/lib/controller.dart:154)
2. `_setupClashConfig()` вызывает `engineManager.setupRuntimePlan(...)`: [lib/controller.dart](/home/max/Projects/FlClashM/lib/controller.dart:696)
3. Только потом `engineManager.start(...)`: [lib/controller.dart](/home/max/Projects/FlClashM/lib/controller.dart:169)
4. После apply ещё синхронно ждутся `updateGroups()`, `updateProviders()` и notification sync: [lib/controller.dart](/home/max/Projects/FlClashM/lib/controller.dart:734)

То есть пользовательский "старт" уже не один boundary, а цепочка из нескольких шагов.

### Длинные таймауты

- `setupConfig()` ждёт до `2` минут: [lib/clash/interface.dart](/home/max/Projects/FlClashM/lib/clash/interface.dart:234)
- `startVpn()` на MethodChannel ждёт до `60` секунд: [lib/clash/lib.dart](/home/max/Projects/FlClashM/lib/clash/lib.dart:232)
- `Service.startService()` на AIDL ждёт до `30` секунд: [android/app/src/main/kotlin/com/follow/clashx/Service.kt](/home/max/Projects/FlClashM/android/app/src/main/kotlin/com/follow/clashx/Service.kt:128)
- внутри `RemoteService.startService()` ещё есть отдельное ожидание `handleStart` до `10` секунд: [android/service/src/main/kotlin/com/follow/clashx/service/RemoteService.kt](/home/max/Projects/FlClashM/android/service/src/main/kotlin/com/follow/clashx/service/RemoteService.kt:173)

Любой нестабильный участок в этой цепочке превращается в очень долгий UX.

### Самое важное архитектурное наблюдение

В проекте уже существует атомарный `quickStart(init + setup + state + foreground bring-up)`:

- Dart-обёртка: [lib/clash/lib.dart](/home/max/Projects/FlClashM/lib/clash/lib.dart:245)
- Android service path: [android/service/src/main/kotlin/com/follow/clashx/service/RemoteService.kt](/home/max/Projects/FlClashM/android/service/src/main/kotlin/com/follow/clashx/service/RemoteService.kt:100)

Но в текущем runtime path он не используется.

Сейчас runtime идёт разорванным способом:

- `setupRuntimePlan()` отдельно;
- `startListener()` отдельно;
- `startVpn()` отдельно.

Это не доказывает автоматически, что именно здесь единственная причина тормозов, но это подтверждённый архитектурный фактор риска и очевидное отличие от более прямого стартового контура.

## 5. Есть дополнительные места риска, которые надо проверять уже на устройстве

### Риск 1. `MihomoEngineAdapter.start()` может считать runtime "уже запущенным"

В [lib/product/runtime/mihomo_engine_adapter.dart](/home/max/Projects/FlClashM/lib/product/runtime/mihomo_engine_adapter.dart:341) есть ранний выход:

- если `readStartTime() != null`, код считает запуск успешным и не вызывает `platform.startVpn()`.

При нормальном state recovery это оправдано. Но при рассинхроне между сохранённым состоянием, реальным VPN и binder/service lifecycle это место потенциально способно давать ложный "started".

По статике это риск, а не подтверждённый дефект.

### Риск 2. Локальный runtime refactor ушёл далеко от upstream Android path

Upstream Android путь был заметно проще: `handleStart()` стартует listener и VPN, а Android-specific re-apply делает уже после старта.

В FlClashM это заменено на новый product runtime orchestration через:

- [lib/product/runtime/engine_manager.dart](/home/max/Projects/FlClashM/lib/product/runtime/engine_manager.dart:94)
- [lib/product/runtime/mihomo_engine_adapter.dart](/home/max/Projects/FlClashM/lib/product/runtime/mihomo_engine_adapter.dart:159)
- [lib/controller.dart](/home/max/Projects/FlClashM/lib/controller.dart:154)

Именно здесь наиболее вероятна часть поведенческого дрейфа относительно рабочего апстрима.

## Что именно сейчас выглядит "точно не так"

### Подтверждённые проблемы

- Режим `cheap-upstream` нарушен большим объёмом локальных изменений вне разрешённых touchpoints.
- Встроенная проверка IP внутри клиента на Android не годится как критерий "VPN реально сменил внешний IP", потому что приложение само исключено из туннеля.
- UI split tunneling в profile-managed режиме скрывает явный summary выбранных приложений.
- В коде есть неиспользуемый safeguard `restoreAndroidProfileSplitTunnelingFields(...)`, что указывает на незавершённую интеграцию.
- Старт/apply path содержит длинную цепочку и большие таймауты.
- Готовый атомарный `quickStart` существует, но текущим runtime path не используется.

### Вероятные, но ещё не доказанные по одной статике

- Реальная утечка device-wide traffic в `DIRECT`, а не только собственного трафика FlClashM.
- Потеря `tun.include-package` или `tun.exclude-package` в конкретных профилях после промежуточной обработки.
- Ложный "runtime уже запущен" через `readStartTime() != null`.

## Рекомендации по исправлению

### Приоритет 1. Вернуть управляемость апстрим-синком

- Зафиксировать, что сейчас проект уже не `cheap-upstream`, а полноценный форк base/UI/runtime.
- Решить, что именно является целевой базой:
  - либо реально возвращаемся к апстримной базе и выносим продуктовые отличия обратно в `lib/product/**` и touchpoints;
  - либо официально признаём fork-mode и перестаём обещать идентичность UI с апстримным APK.
- Для этого отдельно разобрать diff `upstream/dev..main` по группам: UI, runtime, Android bridge, common/models.

### Приоритет 2. Разделить "проверка VPN внутри клиента" и "реальная device-wide проверка"

- Не использовать текущий встроенный IP check как доказательство работы Android VPN.
- Либо убрать self-bypass для самого клиента, если это допустимо архитектурно.
- Либо честно пометить в UI/документации, что встроенная IP-проверка на Android идёт вне туннеля и не отражает routing для других приложений.
- Для реальной диагностики device-wide routing добавить отдельную проверку внешнего приложения или native-side telemetry.

### Приоритет 3. Довести profile split tunneling до прозрачного UX

- В `AccessView` для `_profileManaged == true` показать явный summary:
  - режим `include`/`exclude`;
  - количество выбранных пакетов;
  - список выбранных пакетов отдельным блоком, а не только отметками в общем списке.
- Если профильный список пуст после разрешения селекторов, показывать это явно.
- Поднять live-логирование resolved profile access control при `setupRuntimePlan`, чтобы на устройстве было видно, что реально применилось.
- Решить судьбу `restoreAndroidProfileSplitTunnelingFields(...)`:
  - либо подключить в реальный path;
  - либо удалить как мёртвый код, если он не нужен.

### Приоритет 4. Упростить Android start path

- Перепроверить, можно ли вернуть атомарный `quickStart` в основной Android path вместо разорванного `setupRuntimePlan -> startListener -> startVpn`.
- Свести количество границ и повторных переходов между Dart, MethodChannel, AIDL и remote service.
- Пересмотреть таймауты и добавить этапные логи со временем на каждый шаг:
  - compile runtime plan
  - setup config
  - start listener
  - start foreground/VPN
  - first traffic / first proxy groups

### Приоритет 5. Live-верификация на устройстве

Без этого останутся неподтверждённые риски.

Минимальный план live-диагностики:

1. Логировать resolved `RuntimePlan.profileAccessControl` и итоговые Android VPN options перед `vpn.start(...)`.
2. Логировать `FlVpnService.handleStart()`:
   - route list
   - access control mode
   - include/exclude package lists
   - результат `builder.establish()`
   - результат `Core.startTun`
3. Проверять IP не из FlClashM, а из внешнего приложения, не попавшего в bypass.
4. Снимать временные метки на каждом шаге запуска, чтобы точно найти, где теряется минута.

## Итог

Основная проблема сейчас не в одном точечном баге, а в том, что проект одновременно:

- сильно ушёл от апстрима,
- усложнил базовый Android runtime path,
- оставил неоднозначную диагностику внутри самого клиента,
- и недоделал UX вокруг profile-driven split tunneling.

Если нужен быстрый и надёжный путь к исправлению, то первым делом надо перестать лечить это как "одну поломку", а разложить на:

- базовый drift от upstream,
- Android self-bypass и ложную IP-диагностику,
- отдельный довод split tunneling UX/runtime до прозрачного состояния,
- и отдельный упрощённый start path для Android.
