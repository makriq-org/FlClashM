# Инвентаризация переносимых функций и сценариев

Составлено до реализации по `lib/state.dart`, `lib/controller.dart`,
`lib/models/profile.dart`, `lib/product/{compile,runtime,security,subscription}`,
`core`, `android/{common,service}`. Это перечень обязательств миграции, а не отчёт
о уже пройденных проверках. UI обновления приложения/установщик и релизный каталог
остаются вне runtime backend.

| Функция / сценарий | Текущий владелец | Целевой владелец | Миграция | Проверка поведения |
|---|---|---|---|---|
| YAML/JSON, anchors/merge, порядок групп, описания, GLOBAL override | Dart profile_yaml, RawProfile | Go compiler | Сохранить входной текст и metadata | Совместимые fixtures с baseline, включая merge и неизвестные поля mihomo |
| Импорт файла/URL, редактор, удаление, выбор профиля | Profile + controller | Go repository; UI — действия | Импорт legacy profile IDs/файлов/metadata без потери | Повтор миграции, CRUD/reopen, идентичность исходного текста |
| Подписки, HWID headers, userinfo, disposition, интервалы, newdomain, advisory | Profile.update + product/subscription | Go subscription service | Сохранить headers/URL/даты/интервалы | Локальный HTTP server, redirect/error/timeout, старый профиль при ошибке |
| Уведомления об истечении подписки (3/2/1/0 дней, истекла) | Dart SubscriptionNotificationService | Go notification policy; Android — локализованное отображение | Перенести dedupe по profile/expire/threshold из SharedPreferences | Виртуальные часы, повтор события/reopen/renewal, работа без UI |
| Автообновление подписок без UI | controller.autoUpdateProfiles | Go scheduler | Сохранить autoUpdate и последнее обновление | Виртуальное время, kill/recovery, отсутствие дубликатов |
| Пользовательский JS main(config), override rules | GlobalState.handleEvaluate, compiler | Go compiler | Сохранить script id/content и порядок применения | Fixtures, exception/timeout/cancel, async результат |
| Override network/DNS, hosts, geox, providers paths, external UI, sniffer ports, lazy health checks | Dart ProfileCompiler | Go compiler | Перенести merge и нормализацию | Matrix override flags, совместимые планы |
| Android secure, смешанный порт, TUN, self-bypass | Dart policy + core + VPN Builder | Go SecurityPolicy; Builder — platform | Применять перед validate и каждым update | Защищённый профиль при start/update/recovery, недопустимые пути |
| Split tunneling: package inventory, include/exclude, exact/wildcard/regex, local/remote lists | profile_split_tunneling | Go compiler; inventory — platform | Сохранить приоритеты и приватные каталоги | Совместимые fixtures, пустой include, неполный inventory, offline cache |
| NaiveProxy config/CLI и loopback outbound | Dart node compiler/controller | Go compiler + transport adapter | Сохранить pinned binaries/config artifacts | Fixture config, readiness/failure, stop, исключение shell injection |
| OlcRTC config/CLI и loopback outbound | Dart node compiler/controller | Go compiler + transport adapter | Сохранить validation и pinned binaries | Fixture config, startup error, readiness/cancel |
| StormDNS resolver sources/cache/config | Dart compiler/controller | Go compiler + transport adapter | Сохранить runtime cache fingerprint и resolver files | Offline/TTL/fallback, atomic files, invalid resolver, startup failure |
| ByeDPI manual/auto, strategy lists, foreground budget, background search, network-scoped cache | Dart controller + Kotlin probes | Go compiler/coordinator; процесс — adapter | Перенести кеш и политики выбора | Deterministic SOCKS/HTTP fixtures, cancel, смена сети, кеш и rollback |
| Общие connectivity checks: required/optional, ratios, timeout, concurrency | Dart schema + Kotlin checker | Go checker/coordinator | Сохранить параметры и лимиты | DNS/private/redirect защита, deadline, cancel, success ratio |
| Auto reserve: выбранная группа, health failures, retry, idle sleep, wake | BuiltInProxySupervisor | Go RuntimeCoordinator | Восстанавливать из committed plan, без UI timers | Виртуальное время, stale wake, stop во время probe, active group guards |
| Запуск, остановка, restart, live settings, план без узлов | EngineManager + MihomoEngineAdapter + RemoteService | Go RuntimeCoordinator | Один вход для start/recovery | Порядок действий, idempotency, failure injection на каждом шаге |
| Переключение плана, stage/commit, очистка и rollback | Dart supervisor/controller + Kotlin process manager | Go RuntimeCoordinator | Journal и согласованное поколение | Interrupted operations, failed apply/commit/rollback, reopen |
| Отмена и устаревшие результаты | Dart epochs + Kotlin generations | Go RuntimeCoordinator | operation ID + generation | Concurrent stop/switch/cancel, race detector, late success |
| Cold start / Always-on / boot / tile / widget / notification | SavedParams + FlVpnService + app GlobalState | Go recovery; события — platform | Импорт legacy always-on атомарно с node plan | Headless E2E, process kill, явный stop не восстанавливает VPN |
| VPN fd/protect, permissions, service, notification, wakelock | Android service/platform | Android PlatformAdapter | Убрать orchestration, сохранить fd lifetime | Kotlin unit + emulator start/revoke/destroy, failure cleanup |
| Сеть, системный DNS, screen/Doze, connection reset | Kotlin modules + Dart | Platform events → Go coordinator | Только уведомления ОС, решения в Go | Headless events, stale network scope, отмена фоновых проверок |
| UI attach/detach, traffic/logs/groups, start time | Dart/Kotlin StateHub + core | Go snapshot/events; UI projection | Snapshot+seq, потеря UI не останавливает runtime | Slow subscriber, overflow/resync, reconnect без потери VPN |
| Выбор прокси, mode, health check, providers, connections, tunnel HTTP | Dart core action bridge + Go handlers | Backend API → EngineAdapter | Закрыть обход координатора для mutations | Совместимые ответы UI, persist/recover выбора, concurrent command checks |
| Настройки/бэкап и round trip | Dart Config/preferences | Backend domain storage; UI prefs остаются UI | Сохранить legacy формат импорта/экспорта и неизвестные поля | Import/export/reopen, unknown schema fail closed |
| Android DocumentsProvider и экспорт исходников | FilesProvider + profile files | Go repository; Android — дескрипторы | Виртуальные профили, запись через API с ревизией, скрыть внутренний journal | Round trip исходных байтов, stale editor, запрет записи внутренних файлов |
| Диагностика и редактирование секретов | Dart/Kotlin/core diagnostics | Все границы используют существующий redaction contract | Не публиковать секреты в новых событиях | Общие redaction vectors, лимиты buffers |

Завершение строки требует фактического теста или ссылки на CI evidence. Проверки
наличия строк в исходниках не заменяют эти сценарии. После cutover старые тесты
координаторов удаляются вместе с реализацией; их содержательные regression cases
переносятся в Go/Android tests, а проверки UI и совместимости сохраняются.
