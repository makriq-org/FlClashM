# Единый Go backend

## Размещение и владельцы

Переносимое приложение находится в `core/backend/**` и не импортирует Flutter,
JNI или Android. `core/backend_host.go` — composition root для реального mihomo,
внешних транспортов и Android-механизмов. Desktop-клиенты не входят в эту работу;
переносимость проверяется обычным тестовым host без Android.

```text
Flutter UI / Android tile / widget
              │ JSON API v1: действия, снимки, события
              ▼
 Go service.App ── profiles / subscriptions / settings / notifications
              │
 RawProfile + Settings + PlatformCapabilities
              ▼
 Compiler + SecurityPolicy → validated immutable RuntimePlan
              ▼
 internal RuntimeCoordinator
      ├── EngineAdapter → mihomo
      ├── NodeAdapter → NaiveProxy / OlcRTC / ByeDPI / StormDNS
      └── PlatformAdapter → permission / foreground service / VPN-TUN / OS
```

Flutter хранит представление, черновики редакторов и отправляет пользовательские
действия. Его таймеры обновляют UI, а не runtime. Kotlin предоставляет разрешения,
ресурсы службы, fd/TUN, protect, UID/package inventory, DNS и факты сети/экрана/Doze.
Он не выбирает планы, стратегии или порядок восстановления. StateHub и main-process
GlobalState — проекции Go-снимков, не источники желаемого состояния.

RuntimeCoordinator — единственный владелец изменяемого бизнес-состояния runtime.
В нём находятся сериализация эффектов, preemption/cancel, смена поколений, rollback,
readiness, стратегии ByeDPI, проверки, пробуждение и сон резервных узлов, реакция на
OS-события. Mihomo сохраняет собственные внутренние соединения и наблюдения;
изменяющие команды приложения проходят через очередь координатора.

Внешние транспорты запускаются отдельными процессами. Они не добавлены внутрь
mihomo. NodeAdapter предоставляет prepare/start/stop/observe/listening/probe и
выделение портов. Пути executable, home, ABI и сертификаты задаёт доверенный host,
а не UI или профиль. Аргументы передаются без shell. Нативные артефакты приватны;
SOCKS outbounds ограничены loopback. Linux/Android parent-death binding устраняет
осиротевшие процессы при смерти host.

Обычная, dev, CI-test и локальная диагностическая установки используют разные
диапазоны портов внешних узлов. Занятый порт отклоняется до запуска процесса:
чужой SOCKS listener не считается готовностью собственного узла. Все четыре
пакета исключаются из VPN, чтобы соседняя установка не создала петлю при handover.

## Подготовка и неизменяемый план

Input содержит исходный текст и metadata выбранного профиля, настройки, версии
каталога и профиля. RuntimePlan имеет закрытое представление: plan version,
монотонное поколение, SHA-256 канонического payload. Публичные границы возвращают
копии. Десериализация плана проверяет версию и digest; клиент не может передать
произвольный исполняемый план.

Компилятор сохраняет совместимость YAML/JSON, anchors/merge и scalar semantics,
порядок групп, описания, GLOBAL override, правила и JS `main(config)`. JS выполняется
в отдельной Goja VM с deadline/cancel, без host bindings. Переносятся network/DNS
fallbacks, providers/geo paths, package exact/glob/regexp и локальные/удалённые списки.
Публичные списки ограничены по объёму, времени, redirects и допустимым адресам;
подписки и пользовательские package lists сохраняют поддержку приватных серверов.

SecurityPolicy выполняется до полной проверки движком и sealing: secure mixed port,
ограничение global mode, self-bypass стабильного и debug приложения, итоговые правила
split tunneling. Android Builder буквально применяет результат политики.

Mihomo parser меняет process-global defaults даже при проверке. Поэтому полная
Android-валидация выполняется в отдельном процессе `:validator`, загружающем ту же
библиотеку APK. Временный файл приватен, отмена убивает validator и отбрасывает
поздний ответ. Повреждённая мигрированная запись сохраняется для редактора, но не
исполняется. Отсутствующий URL-исходник восстанавливается отдельной отменяемой
операцией; поздняя загрузка после Stop не запускает VPN.

## Команды, состояния и восстановление

API, storage и plan имеют отдельные версии, сейчас `1`. Запрос содержит
`apiVersion`, `operationId`, `method`, `params`. Ответ содержит result либо error.
Повтор идентичной операции возвращает исходный receipt; повтор ID с другим
содержимым отклоняется. Получение результата и отмена — отдельные команды.

Основные группы API:

| Группа | Назначение |
|---|---|
| snapshot / runtime.view / presentation | Каталог, desired/applied/observed runtime и readonly UI/native-проекция |
| runtime.start / stop / apply / restart / recover / toggle | Намерение исполнения, без клиентского compiled config |
| operation.get / cancel | Результат и явная отмена, независимо от времени жизни IPC |
| settings.patch / profile.* / subscription.refresh / proxy.select | Доменная работа с исходными данными и действиями |
| backup.export / restore / blob.* | Совместимый ZIP и ограниченные переносы через Binder |
| engine.command | Сериализованные transient effects: соединения, traffic, providers, geo |
| ui.attach / data.reset | Backend-политика autoRun; остановка и удаление recoverable-данных |

Доменная операция может вернуть `runtimeOperationId`: это связанный шаг того же
пользовательского действия. Клиент ждёт оба receipt. Отсоединение, timeout ожидания
или смерть Flutter не отменяют операции. AutoRun при открытии UI решает Go, с
устойчивым ID UI-сессии и отдельным результатом необходимости разрешения.

Состояния разделены:

- **Desired** — принятое и сохранённое намерение; Stop сохраняется до эффектов.
- **Applied** — последняя полностью подтверждённая генерация, input, plan и awake
  состояние узлов, зафиксированные вместе.
- **Observed** — фактическое состояние механизмов; недоступное наблюдение означает
  unknown, а не успешно остановленный или запущенный VPN.

`backend-v1.json` сохраняется одним atomic rename с fsync файла и каталога.
Желаемое состояние, generation high-water mark, committed input/plan, pending journal
и ограниченная история receipt не расходятся по разным файлам. При открытии
незавершённые receipt получают interrupted; незавершённые сетевые команды не
проигрываются слепо. Восстановление исполняет последний committed input через тот
же compiler/executor, что обычный запуск. Явный Stop имеет приоритет. Первый
неподтверждённый план не считается резервной копией для recovery.

Компиляция отделена от эффектов. Единственный preparation slot ограничивает память;
Stop не ждёт некооперативный parser. Поколение и context проверяются перед каждым
переходом; устаревший результат не может примениться. Эффекты проходят общую очередь,
cleanup ограничен временем, неудачный переход восстанавливает committed план либо
остаётся fail closed. Идентичный план сохраняет службу и startedAt; явный restart
перезапускает. Live settings и выбор прокси не перестраивают TUN без необходимости.

OS-наблюдения имеют sequence и объединяются по виду. Перед service recovery Go
проверяет фактические ресурсы и поколение; старое onDestroy не отменяет новый Start
или Stop. Отзыв VPN-разрешения сохраняет Stop. Сетевые resets/probes имеют debounce,
health checks учитывают screen/Doze, wakelock — grace period. Эти политики работают
без UI. Внешний HTTP controller проверяет secret до command gate; config/selection
изменяют backend-данные, transient effects входят в ту же очередь. Произвольные
config paths, upgrade и legacy runtime setters закрыты.

## Android и IPC

BackendHost открывается в существующем `:remote` процессе независимо от Flutter.
RemoteService — Binder-мост, его unbind/death отсоединяет только UI. Постоянный Go
listener и автоматические задачи остаются активными. Обычная foreground-служба
держит backend и при VPN, и при proxy-only исполнении; VpnService владеет интерфейсом.
Это сохраняет sticky host при системном unbind VPN после смерти процесса.
OS cold-start/boot вызывает Go recovery.

OperationLifetime удерживает foreground-ресурс во время подготовки и замены плана,
до появления TUN. Лизинг привязан к operationId; освобождение и late Intent
обрабатываются как владение ресурсом, а не второе намерение запуска. VPN fd защищён
владельцем экземпляра службы, чтобы запоздалый teardown не закрыл новый TUN.

Снимок и последующие события не блокируют VPN на медленном подписчике. События
имеют instanceId/sequence, переполнение требует resync. Flutter подписывается до
чтения снимка, отбрасывает старые события и проверяет поколение readonly runtime
view. Смерть процесса меняет instanceId. Native presentation обновляется вне
синхронного Go callback, исключая reentrant lock при уведомлении движка.

Плитки, виджеты, notification title и уведомления об истечении подписки получают
данные из Go. Dedupe уведомлений по profile/expiry/threshold переносится из старых
SharedPreferences; пороги 3/2/1/0 и «истекла» сохранены, Android локализует показ.

## Данные и миграция

Go repository хранит каталог версии 1 и content-addressed оригинальные исходники.
Metadata/settings сохраняют неизвестные поля и большие целые. Изменения используют
CAS ревизий; поздняя подписка или старый редактор не перезаписывают новое содержимое.
Миграция однократная, сохраняет IDs, даты, исходные байты и старые форматы. Legacy
SharedPreferences/исходники не используются как новая runtime authority. Заменённые
Kotlin compiled cold-start файлы удаляются после успешного открытия backend.

Редактор и виртуальный DocumentsProvider работают через Go. Внутренние журналы,
blobs и executable artifacts не публикуются как записываемые файлы. ZIP backup
сохраняет config.json, оригинальные profiles и provider cache; traversal/symlink/
zip-bomb entries отклоняются. Переносы используют chunks 192 KiB, максимум 128 MiB
на файл, 32 незавершённых переноса и 512 MiB суммарно. Все writers соблюдают лимит.
Provider cache восстанавливается atomic rename.

Удаление профиля и выбор следующего фиксируются вместе. Перед удалением последнего
профиля сохраняется Stop. Reset сначала останавливает runtime и удаляет applied input,
дожидается отменённой подготовки, затем очищает исходники/артефакты/переносы. Маркер
миграции и монотонность поколений сохраняются: старые данные не появляются снова.

Заменённые Dart Compiler/EngineManager/SecurityPolicy, Kotlin node process manager,
network/health/suspend coordination, quickStart и SavedParams удалены. В Dart runtime
каталоге остались только версии/ABI-метаданные для setup.dart и упаковки APK.

## Этапы PR и проверка

Инвентаризация сценариев составлена в [inventory.md](inventory.md) до реализации.
PR #116 зафиксировал архитектуру; #117 актуализировал main и baseline;
#118 реализовал переносимый координатор. По разрешению владельца оставшаяся работа
(данные, compiler, Android cutover и удаление старых путей) объединена в PR #119.
Все PR направляются только в `refactor/go-backend`; `main` не изменяется.

Go host tests проверяют совместимость, безопасность, отмену, rollback, interrupted
recovery, source CAS, автономные узлы, OS-политику, уведомления и IPC-протокол. CI
дополнительно запускает root/core tests, vet/race, Flutter tests/analyze, Kotlin unit
checks, Android ABI builds и x86_64 emulator E2E. E2E использует локальный профиль,
настоящие validator/ByeDPI/TUN, большой Binder payload, смерть UI и :remote. Публичные
проверочные URL отключены; сетевые host-тесты используют контролируемые fixtures.

Текущее добавление сценария не является доказательством прохождения CI. Итоговые
run URLs фиксируются после завершения проверок. Сборка ARM и эмулятор не считаются успешной аппаратной проверкой. Результаты
физической проверки ниже относятся только к указанному ABI и устройству;
Wi-Fi↔mobile handover и энергопотребление требуют отдельного прогона.

## Отдельная тестовая установка

ARM64 smoke-сборка push в `refactor/go-backend` публикуется артефактом
`android-arm64-test-apk`. Пакет `com.makriq.flclash.backendtest` имеет название
`FlClashM Backend Test`, отдельные данные и debug-подпись, включая release-режим
компиляции. Он устанавливается рядом с обычным и `.dev` клиентами.
Для ручной сборки workflow поддерживает input `backend_test`; локально достаточно
`ORG_GRADLE_PROJECT_backendTest=true flutter build apk --release --target-platform android-arm64`
после подготовки Android runtime-артефактов.

Для локальной диагностики рядом с APK из CI используется отдельный пакет
`com.makriq.flclash.backendcheck`, название `FlClashM Backend Check` и локальная
debug-подпись. Сборка воспроизводится без изменения исходников:

```sh
nix develop
dart setup.dart android --arch arm64 --out core
ORG_GRADLE_PROJECT_backendDiagnostic=true flutter build apk --debug --target-platform android-arm64
```

Исходный профиль можно перенести резервной копией; данные установок независимы.
Для ROM, требующих отдельного подтверждения установки той же версии, локальный
номер и имя можно передать через `--build-number` / `--build-name` без изменения
`pubspec.yaml` и без релизного тега. В CI остаётся прежний `backendTest=true`.

Удалённые списки приложений читаются сначала из прежнего кэша профиля. Go обновляет
проверенное содержимое фоновыми задачами своего жизненного цикла с ограничением
времени и параллелизма. Ошибка сети сохраняет предыдущий список; сброс данных
отменяет обновление и запрещает позднюю запись кэша. Без сохранённого списка
первая загрузка ограничена 20 секундами; ошибка не превращается в пустую политику.

## Проверка исправлений на устройстве, 18 октября 2026

На vivo V2361A (arm64-v8a) локальная диагностическая установка прошла native E2E:
настоящие mihomo/validator/ByeDPI/TUN, передача профиля больше 1 МиБ через Binder,
проверка правил непосредственно в ядре, два перезапуска, восстановление,
откат ошибочного редактирования, автономный Stop и proxy-only режим. Сервер списка
приложений выключался после единственной загрузки; последующие запуски использовали кэш.

На копии реального профиля проверены vendor-запрос доступа к установленным пакетам,
открытие UI с произвольным адресом контроллера, обновление профиля с завершением
индикатора загрузки и все семь правил в mihomo.
Один DE Naive дал HTTP 204 в global и rule. Выбор прокси через API занял 85–160 мс;
это длительность операции backend, без времени жеста и отрисовки Flutter.
Принудительное завершение Naive с последующим перезапуском восстановило процесс,
правила и HTTP 204. После принудительного завершения процесса backend приложение
также восстановило VPN и HTTP 204 с прежними правилами. Эти результаты не распространяются на остальные ABI и ROM.

После `onServiceDisconnected` IPC освобождает старое подключение и создаёт новое с
ограниченным повтором; счётчик неудач сбрасывается при успешной привязке. UI не
запоминает неудачное подключение навсегда, объединяет одновременные ожидания и
отбрасывает поздний ответ от заменённой связи. Повторный Start/Stop одного намерения
разделяет текущую операцию; противоположное действие остаётся немедленным.
