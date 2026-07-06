# Upstream Drift Report

## Сводка

Точка расхождения: `b8dab32a6c5d8e61625e2dd6192ca69f9680d016`.

После этой точки `upstream/dev` ещё не менял те же пути, поэтому приоритет ниже оценён по роли файла и размеру дельты, а не по уже случившимся коллизиям. Опора для `INCAPSULATE` взята из `tool/product_touchpoints.json`: там уже зафиксированы допустимые тонкие точки монтирования, и именно к ним стоит сводить base-дельту.

| Зона | Файлы | Вставки | Удаления | Суммарная дельта |
| --- | ---: | ---: | ---: | ---: |
| `lib` вне `product/l10n` | 146 | 3941 | 4930 | 8871 |
| `android` | 53 | 900 | 261 | 1161 |
| `core` | 2 | 18 | 2 | 20 |
| Итого | 201 | 4859 | 5193 | 10052 |

| Корзина | Файлы | Вставки | Удаления | Суммарная дельта |
| --- | ---: | ---: | ---: | ---: |
| `INCAPSULATE` | 27 | 2161 | 2671 | 4832 |
| `BUDGET` | 63 | 2172 | 1947 | 4119 |
| `REVERT` | 111 | 526 | 575 | 1101 |

`DELETE-CONFLICT` риск есть у трёх удалённых base-файлов: `lib/manager/tile_manager.dart`, `android/app/src/main/res/drawable/ic.xml`, `android/app/src/main/res/drawable/ic_launcher_foreground.xml`.

## Таблица по файлам

| Путь | Дельта строк | Корзина | `delete-conflict` | Краткое обоснование | Предлагаемое действие |
| --- | --- | --- | --- | --- | --- |
| `lib/controller.dart` | `+711/-1011` | `BUDGET` | нет | Центральная оркестрация `AppController`, запуск/остановка runtime, связка с `EngineManager`, обновление конфигурации и состояния. Это базовый поток приложения, а не вставной продуктовый виджет. | Зафиксировать как бюджетный якорь. Новую продуктовую политику в файл не добавлять; оставшееся вынесение делать только в сервисы под `lib/product/**`, сам файл держать как тонкий оркестратор. |
| `lib/views/dashboard/widgets/hero_connect.dart` | `+593/-998` | `INCAPSULATE` | нет | Крупный продуктовый редизайн главного экрана и карточки подключения. Самый дорогой визуальный дрейф в `lib`. | Вынести весь виджет в продуктовый слой. Реалистичная цель для base-файла: 1–3 строки вызова продуктового виджета вместо текущих 1591 строк дельты. |
| `lib/state.dart` | `+282/-495` | `BUDGET` | нет | Глобальная связка `RuntimeRegistry`, `EngineManager`, вызовов compile/security и жизненный цикл ядра. Это несущая base-инфраструктура. | Зафиксировать как бюджетный якорь. Держать только связку и вызовы контрактов, не вносить сюда новую продуктовую логику напрямую. |
| `lib/views/config/general.dart` | `+338/-375` | `INCAPSULATE` | нет | Большой продуктовый пересмотр общей страницы настроек и быстрых действий. Для синка это тяжёлый визуальный узел. | Вынести страницу или крупные секции в `lib/product/**`. Реалистично ужать base до 10–20 строк монтирования вместо 713 строк дельты. |
| `lib/providers/state.dart` | `+174/-189` | `INCAPSULATE` | нет | В горячем base-файле сидят продуктовые селекторы платформы и подсказок провайдера. Это повышает шанс конфликтов на любом визуальном изменении апстрима. | Перенести продуктовые селекторы в отдельный продуктовый модуль и оставить в base только 1–3 тонких провайдера-обёртки. |
| `lib/views/profiles/profiles.dart` | `+161/-156` | `INCAPSULATE` | нет | Профильные действия и подсказки провайдера вплетены прямо в base-страницу. | Вынести меню подсказок и продуктовые действия в продуктовый построитель карточки. Цель: base-дельта порядка 10–15 строк вместо 317. |
| `lib/views/dashboard/dashboard.dart` | `+160/-155` | `INCAPSULATE` | нет | Состав дашборда и выбор между base/product-видами сидит в base-странице. | Перенести композицию дашборда в продуктовый построитель. Цель: 10–15 строк точки монтирования вместо 315 строк дельты. |
| `lib/views/access.dart` | `+136/-107` | `INCAPSULATE` | нет | Редактор контроля доступа фактически стал продуктовым сервисом, но его состояние и поведение всё ещё размазаны по base-странице. | Оставить в base только каркас страницы и вызов продуктового редактора. Реалистичная цель: 10–20 строк вместо 243. |
| `lib/main.dart` | `+2/-208` | `INCAPSULATE` | нет | Файл уже почти приведён к правильной форме: единственная передача управления в `AppBootstrap`. Но дельта к апстриму всё ещё большая, потому что старый base-код полностью исчез. | На синках брать свежий апстримный `main.dart` и снова сводить его к одному вызову `AppBootstrap.run()`. Цель уже достигнута: 1 строка. |
| `lib/views/theme.dart` | `+101/-103` | `REVERT` | нет | Почти целиком форматирование и механическая правка без продуктовой пользы. | Откатить к апстримной версии. Это быстрый чистый выигрыш примерно на 204 строки конфликтной поверхности. |
| `android/service/src/main/kotlin/com/follow/clashx/service/RuntimeNodeProcessManager.kt` | `+193/-0` | `BUDGET` | нет | Новый супервизор runtime-узлов живёт в платформенном сервисе Android. Вынести его в `lib/product/**` невозможно: это Kotlin-часть слоя runtime/platform. | Принять в бюджет, но держать интерфейс минимальным и стабильным. Любые новые узлы подключать через тот же контракт, без разрастания AIDL. |
| `lib/views/application_setting.dart` | `+102/-62` | `INCAPSULATE` | нет | Продуктовая политика обновлений и доп. переключатели вплетены в base-страницу настроек. | Вынести продуктовую секцию настроек в отдельный виджет. Цель: 5–10 строк монтирования вместо 164 строк дельты. |
| `android/service/src/main/kotlin/com/follow/clashx/service/FlVpnService.kt` | `+135/-27` | `BUDGET` | нет | Автозапуск при always-on, runtime-узлы и корректная семантика контроля доступа лежат в самом VPN-сервисе. Это платформа и жизненный цикл, а не визуальный слой. | Принять в бюджет. Дальше фиксировать контракт и не добавлять в этот файл продуктовые ветвления сверх уже существующих. |
| `lib/common/utils.dart` | `+117/-25` | `BUDGET` | нет | Здесь сидит общая логика сравнения версий, в том числе для предрелизов. Это не продуктовый виджет и не слой подсказок провайдера. | Оставить в base как общий багфикс. |
| `android/app/src/main/kotlin/com/follow/clashx/plugins/AppPlugin.kt` | `+90/-39` | `BUDGET` | нет | Нативный мост для списка пакетов, открытия файлов и установки `apk`. Это Android-мост, не переносимый в `lib/product/**`. | Принять в бюджет и держать как технический мост без продуктовой политики внутри. |
| `lib/services/subscription_notification_service.dart` | `+58/-53` | `INCAPSULATE` | нет | Логика подсказок провайдера и продуктовых названий попала в base-сервис уведомлений. | Перенести сервис целиком в продуктовый слой или оставить в base только тонкий вызов продуктового помощника. Цель: 3–5 строк вместо 111. |
| `android/service/src/main/kotlin/com/follow/clashx/service/modules/NetworkObserveModule.kt` | `+101/-6` | `BUDGET` | нет | Реальный багфикс DNS и выбора системной сети внутри Android service. Это чистый слой platform/runtime. | Оставить в бюджете. |
| `lib/views/profiles/edit_profile.dart` | `+52/-49` | `INCAPSULATE` | нет | В base-редактор вшит продуктовый валидатор конфигурации. | Оставить только вызов продукта через контракт, всю политику проверки держать в `lib/product/**`. |
| `lib/application.dart` | `+21/-79` | `INCAPSULATE` | нет | Допустимая точка монтирования уже есть, но файл ещё несёт Android-only композицию и вычищенные desktop-ветки относительно апстрима. | Вернуть базовую оболочку как можно ближе к апстриму и оставить только разрешённые product hooks. Реалистичная цель: 3–5 строк сверх апстрима. |
| `lib/views/dashboard/widgets/stats_grid.dart` | `+80/-18` | `INCAPSULATE` | нет | Дополнительные продуктовые плитки статистики лежат в базовом виджете. | Вынести продуктовую раскладку в отдельный виджет; base оставить только точкой вызова. |
| `android/common/src/main/kotlin/com/follow/clashx/common/SavedParams.kt` | `+80/-10` | `BUDGET` | нет | Миграция сохранённого состояния always-on и runtime nodes — это часть Android-слоя platform/runtime. | Принять в бюджет и не расширять формат без явной нужды. |
| `lib/views/about.dart` | `+50/-29` | `INCAPSULATE` | нет | Проверка обновлений, ссылки и часть контента жёстко продуктовые. | Вынести продуктовые секции и обработчик обновлений. Цель: 5–10 строк в base. |
| `lib/views/config/network.dart` | `+35/-33` | `REVERT` | нет | Почти весь дрейф здесь косметический: форматирование, удаление лога, механические правки. | Откатить к апстриму. |
| `lib/manager/tile_manager.dart` | `+0/-68` | `REVERT` | да | Файл удалён, хотя в апстриме он жив. Это гарантированный modify/delete-конфликт на каждом синке. | Восстановить инертный адаптер или близкую к апстриму оболочку, которая просто делегирует текущему Android-мосту оболочки. |
| `lib/models/profile.dart` | `+42/-24` | `INCAPSULATE` | нет | В base-модель попали продуктовые обратные вызовы валидации и заголовки подсказок провайдера. | Держать в модели только нейтральные данные и базовый ввод-вывод; интерпретацию заголовков перенести в продуктовый конвейер. |
| `android/app/src/main/kotlin/com/follow/clashx/plugins/ServicePlugin.kt` | `+62/-3` | `BUDGET` | нет | Kotlin-мост quick-start/runtime-node/notification action. Это сервисный мост. | Принять в бюджет и не размывать контракт. |
| `lib/plugins/vpn.dart` | `+12/-45` | `BUDGET` | нет | Файл уже стал тонким мостом к native service; дальше ужимать почти нечего. | Оставить в бюджете как тонкую обвязку. |
| `lib/clash/lib.dart` | `+20/-35` | `BUDGET` | нет | Канал связи с Android service, quick-start и обновление уведомления — это базовый мост runtime-слоя. | Принять в бюджет; не возвращать сюда продуктовую политику контроля доступа. |
| `android/app/src/main/kotlin/com/follow/clashx/GlobalState.kt` | `+45/-6` | `BUDGET` | нет | Проверка фактического VPN, запрос исключения из оптимизации батареи и каналы уведомлений живут в Android-состоянии приложения. | Принять в бюджет как исправление платформенного жизненного цикла. |
| `lib/common/request.dart` | `+31/-16` | `BUDGET` | нет | Общий сетевой слой, исправления загрузки и принудительного mixed-port для IP-проверки. | Оставить в base как общий багфикс. |
| `android/app/build.gradle.kts` | `+34/-7` | `BUDGET` | нет | `applicationId`, определение типа keystore и dev-suffix нельзя вынести в `lib/product/**`. | Принять в бюджет. |
| `lib/common/link.dart` | `+29/-11` | `BUDGET` | нет | Исправление initial link и дедупликации deep-link событий, это общая base-функция. | Оставить в бюджете. |
| `lib/pages/home.dart` | `+19/-20` | `INCAPSULATE` | нет | Выбор между base/product навигацией и дашбордом привязан к продуктовой подсказке. | Оставить только чтение готового продуктового флага, остальное вернуть ближе к апстриму. |
| `lib/views/dashboard/widgets/announce_widget.dart` | `+10/-29` | `INCAPSULATE` | нет | Базовый виджет начал знать о продуктовой строке-подсказке. | Пусть продукт отдаёт уже готовый текст; базовый виджет только рисует его. |
| `android/app/src/main/res/drawable/widget_logo_color.xml`, `android/app/src/main/res/drawable/widget_logo_mono.xml`, `android/app/src/main/res/{drawable-*,mipmap-*}/ic_launcher*`, `android/app/src/main/res/{values,values-ru}/strings.xml`, `android/common/src/main/res/values*.xml`, `android/service/src/main/res/drawable/ic_notification.xml` | `+27/-63` и бинарные замены | `BUDGET` | нет | Это брендинг форка, названия каналов и ресурсные оболочки поверх новых иконок. Для продукта это обязательно, но к `lib/product/**` не относится. | Принять в бюджет как осознанный форковый ресурсный дрейф. |
| `lib/common/http.dart` | `+25/-12` | `BUDGET` | нет | Базовая логика поиска прокси и отключение небезопасного `badCertificateCallback`. | Оставить как base-багфикс. |
| `lib/views/dashboard/widgets/service_info_widget.dart` | `+9/-27` | `INCAPSULATE` | нет | Базовый виджет знает о продуктовых подсказках провайдера. | Перенести извлечение этих данных в продуктовый слой; base оставить только рисование. |
| `android/app/src/main/AndroidManifest.xml` | `+19/-12` | `BUDGET` | нет | Права на установку `apk`, deep-link схема форка, tile-service rename и лейблы приложения нельзя вынести из Android base. | Принять в бюджет. |
| `android/app/src/debug/AndroidManifest.xml`, `android/service/src/main/AndroidManifest.xml` | `+6/-6` | `BUDGET` | нет | Отладочный ярлык и подписи special-use FGS должны совпадать с форком. | Принять в бюджет. |
| `android/app/src/main/kotlin/com/follow/clashx/FlClashApplication.kt`, `android/app/src/main/kotlin/com/follow/clashx/MainActivity.kt`, `android/app/src/main/kotlin/com/follow/clashx/Service.kt`, `android/app/src/main/kotlin/com/follow/clashx/TempActivity.kt` | `+32/-6` | `BUDGET` | нет | Инициализация процесса, регистрация плагинов, клиентские методы для runtime-node и rename tile-service — это Android-точка входа. | Принять в бюджет и держать контракты узкими. |
| `android/app/src/main/kotlin/com/follow/clashx/widgets/ModeWidgetProvider.kt`, `android/app/src/main/kotlin/com/follow/clashx/widgets/OnOffWidgetProvider.kt`, `android/app/src/main/kotlin/com/follow/clashx/services/FlClashMTileService.kt` | `+11/-9` | `BUDGET` | нет | Пространства имён и новый класс tile service привязаны к форку. | Принять в бюджет. |
| `android/common/src/main/kotlin/com/follow/clashx/common/Components.kt`, `android/common/src/main/kotlin/com/follow/clashx/common/Ext.kt`, `android/common/src/main/kotlin/com/follow/clashx/common/GlobalState.kt` | `+20/-13` | `BUDGET` | нет | Динамическое вычисление runtime package и новых action names — это служебная платформенная склейка. | Принять в бюджет. |
| `android/service/src/main/aidl/com/follow/clashx/service/IRemoteInterface.aidl`, `android/service/src/main/kotlin/com/follow/clashx/service/CommonService.kt`, `android/service/src/main/kotlin/com/follow/clashx/service/FilesProvider.kt`, `android/service/src/main/kotlin/com/follow/clashx/service/RemoteService.kt`, `android/service/src/main/kotlin/com/follow/clashx/service/models/NotificationParams.kt` | `+46/-5` | `BUDGET` | нет | Это сервисный контракт и вспомогательная платформенная обвязка runtime nodes/уведомлений. | Принять в бюджет. |
| `android/app/src/main/res/drawable/ic.xml` | `+0/-12` | `REVERT` | да | Удаление старого alias-ресурса не даёт продуктовой пользы, но гарантирует modify/delete-конфликт. | Восстановить инертный alias к текущему launcher-ресурсу. |
| `android/app/src/main/res/drawable/ic_launcher_foreground.xml` | `+0/-35` | `REVERT` | да | Удалён живой в апстриме foreground XML. Это вечный modify/delete-конфликт без функционального выигрыша. | Восстановить обёртку поверх текущего foreground-asset, даже если реальная иконка теперь PNG. |
| `core/lib_android.go` | `+18/-1` | `BUDGET` | нет | Нормализация системных DNS-серверов — это точечный базовый багфикс в Android-склейке с `mihomo`. | Принять в бюджет. |
| `core/utls/internal/cpu/cpu_s390x.s` | `+0/-1` | `REVERT` | нет | Случайное удаление пустой строки, продуктовой ценности нет. | Откатить к апстриму. |
| `lib/clash/{core.dart,interface.dart,message.dart,service.dart}` | `+17/-17` | `REVERT` | нет | Пакетное переименование импортов без изменения поведения. | Откатить к апстримной форме импорта. |
| `lib/common/*`, кроме `http.dart`, `link.dart`, `request.dart`, `system.dart`, `utils.dart` | `+65/-62` | `REVERT` | нет | Почти весь дрейф — механическое переименование пакета и форматирование. | Откатить к апстриму пачкой. |
| `lib/manager/*`, кроме `android_manager.dart`, `app_state_manager.dart`, `clash_manager.dart`, `tile_manager.dart` | `+30/-31` | `REVERT` | нет | Механический шум без продуктовой функции. | Откатить к апстриму пачкой. |
| `lib/models/{app,clash_config,common,core,selector}.dart` | `+11/-11` | `REVERT` | нет | Только шум от импортов и форматирования. | Откатить к апстриму. |
| `lib/pages/editor.dart`, `lib/pages/scan.dart`, `lib/plugins/{service,tile}.dart`, `lib/providers/app.dart`, `lib/utils/device_info_service.dart` | `+14/-14` | `REVERT` | нет | Механический шум и мелкие асинхронные правки без продуктовой сущности. | Откатить пачкой. |
| `lib/views/{backup_and_recovery,config/config,config/dns,config/network,connection/*,developer,hotkey,logs,profiles/add_profile,profiles/override_profile,profiles/receive_profile_dialog,profiles/scripts,proxies/*,resources,tools}.dart` | `+187/-188` | `REVERT` | нет | В основном шум от импортов, форматирования и мелкой косметики. Функциональная разница либо отсутствует, либо слишком мала для отдельного базового долга. | Откатить к апстриму пачкой. |
| `lib/widgets/*` | `+57/-57` | `REVERT` | нет | Полностью шум от импорта и форматирования. | Откатить пачкой. |

## Топ-10 очагов

| Очаг | Почему он наверху | План действия |
| --- | --- | --- |
| `lib/controller.dart` | Самая большая дельта во всём дереве и очень горячий base-файл. | Не инкапсулировать силой. Записать в бюджет и запретить новые продуктовые ветвления в обход `lib/product/**`. |
| `lib/views/dashboard/widgets/hero_connect.dart` | Самый тяжёлый продуктовый визуальный дрейф. Любое обновление апстримного дашборда будет биться сюда. | Вынести весь виджет в продуктовый слой. Base оставить как 1–3 строки вызова. |
| `lib/state.dart` | Глобальная связка runtime-слоя, высокий риск конфликтов при любом движении base-ядра. | Зафиксировать как бюджетный якорь и держать только контракты compile/security/runtime. |
| `lib/views/config/general.dart` | Большая продуктовая страница настроек внутри base. | Вынести страницу или крупные секции в `lib/product/**`, base вернуть ближе к апстриму. |
| `lib/providers/state.dart` | Очень горячий селекторный файл, куда уже протекли продуктовые подсказки и режимы платформы. | Перенести продуктовые провайдеры в отдельный модуль и оставить в base минимальные адаптеры. |
| `lib/views/profiles/profiles.dart` | Плотная визуальная страница апстрима, но с продуктовым слоем подсказок внутри. | Вынести меню подсказок и поддержку провайдера в продуктовый построитель карточки. |
| `lib/views/dashboard/dashboard.dart` | Большая base-страница, завязанная на выбор product dashboard. | Перенести композицию секций в продуктовый построитель. |
| `lib/views/access.dart` | Большой base-файл, который уже фактически работает как клиент продуктового сервиса. | Оставить в base только каркас страницы и подключение продуктового редактора доступа. |
| `android/service/src/main/kotlin/com/follow/clashx/service/FlVpnService.kt` | Горячая точка Android жизненного цикла и always-on. Любая синхронизация runtime-слоя будет приходить сюда. | Зафиксировать контракт runtime-nodes и контроля доступа; не добавлять новые продуктовые ветки прямо в сервис. |
| `lib/views/theme.dart` | Быстрый и дешёвый выигрыш: большая дельта без реальной пользы. | Откатить к апстриму целиком. |

Сразу под чертой по приоритету стоят `android/app/src/main/kotlin/com/follow/clashx/plugins/AppPlugin.kt`, `android/common/src/main/kotlin/com/follow/clashx/common/SavedParams.kt`, `lib/application.dart`, `lib/views/application_setting.dart` и удалённый `lib/manager/tile_manager.dart`.

## Список `delete-conflict` файлов

| Путь | Рекомендация |
| --- | --- |
| `lib/manager/tile_manager.dart` | Восстановить как инертную оболочку, совместимую с апстримным путём и делегирующую в новый Android-мост оболочки. Это уберёт вечный modify/delete-конфликт и сохранит дешёвый sync. |
| `android/app/src/main/res/drawable/ic.xml` | Восстановить как простой alias к текущей launcher-иконке. Удаление не даёт функциональной пользы, а конфликт будет постоянным. |
| `android/app/src/main/res/drawable/ic_launcher_foreground.xml` | Восстановить как обёртку над текущим foreground-asset. Даже пустая инертная оболочка лучше, чем вечный modify/delete-конфликт. |

## Вывод

Самая дорогая часть дрейфа уже хорошо локализуется. В `BUDGET` должны остаться в основном `lib/controller.dart`, `lib/state.dart` и Android-слой runtime/service. Почти весь тяжёлый визуальный дрейф в `lib/views/**` и часть продуктово-зависимых моделей/селекторов можно ужать до разрешённых точек монтирования из `tool/product_touchpoints.json`. Отдельно виден дешёвый быстрый выигрыш: большой пласт `REVERT` — это просто шум от переименований, форматирования и трёх удалений с гарантированным `delete-conflict`.
