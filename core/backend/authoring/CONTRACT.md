# Конструктор профилей: Go API v1

Источник моделей и поведения: upstream/0.5.0-dev,
`5b38c0c7dfba726b8335407d0df5e6205e2d9bfa`.

## Хранение и квитанции

Все команды используют существующий envelope `{apiVersion:1, operationId,
method, params}`. Изменения проходят журнал application-v1 и возвращают обычную
квитанцию; результат читается через `operation.get`. Повтор того же operationId
с теми же параметрами возвращает прежнюю квитанцию. Другие параметры с тем же ID
отклоняются. `revision` — общая ревизия каталога, включая изменения настроек и
подписок. CAS обязателен: нулевая ревизия также сравнивается буквально.

`authoring.snapshot` → `{revision, profiles:[metadata], collections}`. Оба массива
данных получены под одним mutex каталога. Коллекции всегда присутствуют, даже
пустые: `scripts`, `rules`, `disabledRules`, `proxyGroups`, `clashProviders`,
`customProxies`, `proxyDialers`, `iconRecords`, `iconSets`.

`authoring.replace` принимает:

```json
{
  "expectedRevision": 12,
  "profiles": [{"id":"profile:string-id","type":"custom","label":"My profile"}],
  "deletedProfileIds": [],
  "collections": {
    "scripts": [], "rules": [], "disabledRules": [], "proxyGroups": [],
    "clashProviders": [], "customProxies": [], "proxyDialers": [],
    "iconRecords": [], "iconSets": []
  }
}
```

`profiles` и `deletedProfileIds` необязательны. Metadata — upsert, порядок
перечисленных профилей сохраняется; отсутствующие профили остаются после них.
Удаление только явное. Существующие источники, digest и неизвестные metadata
сохраняются; новые custom-профили создаются без source. Для нового профиля с
исходным файлом применяются существующие `profile.import.file`/`.url`.
Коллекции заменяются полностью; отсутствующая коллекция становится пустой.
Metadata, декларации, удаления и замена текущего профиля фиксируются одной CAS
транзакцией. Удаление последнего профиля предварительно журналирует Stop через
координатор, как существующий `profile.delete`. Ошибки CAS/валидации ничего не
фиксируют. Последующая ошибка компиляции не отменяет сохранение; квитанция
содержит ревизию сохранения и отдельный `runtimeOperationId`, когда был apply.

Для больших коллекций вместо `collections` допустим `token` blob с JSON самих
коллекций. Metadata и tombstones остаются полями запроса. Лимит документа 32 MiB,
одного исходника/ресурса 16 MiB. UI не передаёт файловые пути.

Строки деклараций — upstream toJson без SQL-кодирования. Все `profileId` и
metadata.id **строки**, nullable profileId у глобального правила допустим.
Остальные snowflake ID — JSON int64 без преобразования через float64.
`rules` дополняются `profileId`; `disabledRules` — `{profileId,ruleId}`;
`proxyDialers` — `{profileId,proxyId,target}`. Scripts содержат `content:string`.
Rule providers содержат `contentBase64:string` с исходными байтами; пустая строка
означает отсутствие скачанного remote-ресурса. Также читается `content:string`
для совместимости. Неизвестные поля деклараций сохраняются.

## Компиляция и импорт

Go собирает custom-профиль из серверов, групп, правил, dialer chains и источников
подписок. Неиспользуемые серверы/провайдеры не включаются; include-all, прямые цели
правил, резервные выходы групп (empty-fallback) и зависимости цепочек учитываются.
Подписки предоставляются mihomo как inline proxy providers.
Их внешние транспорты проходят тот же ExternalCompiler и RuntimeCoordinator.
Циклы групп/цепочек, неизвестные ссылки и дубли имён отклоняются.

Обычные профили сохраняют исходники, legacy overrideData/scriptProps/overrideDns.
Добавленные правила профиля идут перед глобальными, disabledRules исключаются,
MATCH-placeholder получает matchTarget или последний MATCH исходника. Выбранный
scriptId из declarations исполняется изолированным Goja; custom-профили scripts
не исполняют, как upstream. SecurityPolicy и изолированный engine validator
используются и для custom-планов.

`overrides` metadata и общий `patchClashConfig` поддерживают `dns`, `ntp`,
`sniffer` и массивы `dns-override-keys`, `ntp-override-keys`,
`sniffer-override-keys` с upstream путями. Пример:
`{"dns-override-keys":["nameserver","fallback-filter.domain"],"dns":{...}}`.
Общие ключи применяются первыми, профильные последними; невыбранные значения
сохраняются. Sniff-протоколы заменяются без учёта регистра. Android VPN/TUN
остаётся под действующей политикой; NTP write-to-system принудительно выключен.
Отсутствие новых массивов сохраняет прежний whole-DNS override.

`authoring.import` → receipt с `profileId,revision`:
`{expectedRevision, profileId?, metadata?, source|token, ageSecretKey?, links?,
select?, replace?, providerSources?:{providerName:blobToken}}`.
Создаёт или дополняет custom-профиль, переименовывает коллизии и ссылки,
переиспользует одинаковые proxy definitions и provider URL. `replace:true`
заменяет принадлежащие профилю группы/правила/цепочки. Inline и HTTP providers
импортируются как backend-owned данные; file provider требует явного blob token,
его path никогда не открывается. Данные сохраняются одним CAS после загрузки.
`authoring.parseLinks {source|token}` → `{proxies:[raw mihomo mapping]}` — pure
preview без runtime. Нераспознанная строка ссылок возвращает ошибку.

## Preview и экспорт

- `profile.inspect {profileId}` → `{config,outbounds,base,diagnostics,...}`.
  config — разобранный исходник или композиция custom declarations без scripts;
  outbounds — `{proxies:[],"proxy-groups":[],"proxy-providers":{}}`.
  base — `{config,digest,present,proxies,"proxy-groups",rules,"match-rules"}`:
  counts — числа, present — список явно названных ключей, включая tun.*;
  base.config исключает proxies/proxy-groups/rules/sub-rules.
- `profile.render {profileId}` → receipt с `blob:{token,size}`. Собирает и
  валидирует полный конфиг, не запускает его. Blob содержит JSON, совместимый с
  YAML; внутренние resource paths принадлежат backend.
- `profile.export` сохраняет прежний byte-for-byte source обычного профиля;
  для custom возвращает скомпилированный конфиг через blob.
- `profile.validate {token,ageSecretKey}` → `{message}` синхронно; пустая строка
  только после действительной валидации. Ошибка декодирования/валидации — message.
  Явное поле ageSecretKey выбирает этот режим (может быть пустым). Старые запросы
  без него продолжают возвращать receipt, принимая source или token.
- `authoring.evaluate {script,config}` → `{config}`: Goja sandbox без fs, сети,
  process bindings, с тайм-аутом 2 секунды. Никаких записей или runtime effects.

AGE расшифровывается только переданной identity, без глобальных engine keys.

## Ресурсы и очистка

`authoring.resource.update {collection,id}` → receipt: HTTP(S) download через
host HTTPClient, ограничение размера/времени, классификация rule set и CAS по
ревизии начала операции. Старый ответ не перезаписывает отредактированные данные.
collection: `scripts|clashProviders|iconSets`; никакого Dart IO/scheduler.
`authoring.resource.read {collection,id}` → `{contentBase64,size,lastModified?}`.
LastModified — ISO timestamp последнего сохранения/скачивания.

Дополнительные методы: `resource.get {collection,id}` →
`{revision,declaration}`, `resource.put {collection,id,expectedRevision,
content|contentBase64|token}` → receipt; `resource.refresh` аналогичен update,
но требует expectedRevision. Для iconSets скачанный JSON содержит массив icons
или объект `{icons:[{name,url}]}`.

Локальные rule sets классифицирует pure `core/profilecodec`. Domain/IP CIDR
материализуются в MRS; исходные байты остаются в каталоге для редактора/backup.
Файлы именуются по SHA256 содержимого под trusted ProfilesDir/providers/authoring;
новая редакция не меняет файл активного/откатываемого плана. Remote без сохранённых
байтов остаётся HTTP provider в декларативном engine config.

`storage.clearCache {}`, `storage.collect {}`, `profile.clearCache {profileId}`
возвращают receipt и не меняют profiles/settings/authoring. Engine effects идут
через `Backend.SubmitEngineCommand` с generation fence и той же очередью, что Stop:

- clear всех caches → `EngineCommand{Method:"cache.clear",Params:{}}`;
- clear профиля → `cache.clear`, `Params:{profileId:string}`;
- collect → `cache.collect`, `Params:{}`.

**Контракт интегратора:** root backendEngine.Command реализует cache.clear/collect
для engine/provider/geo caches из своих trusted paths. Нельзя удалять активные
nodes, файлы committed/pending планов и используемые скомпилированные ресурсы.
Backend дополнительно очищает только недостижимые original-source blobs после
cache.collect; после общего clear сбрасывает PackageListCache. Ошибка адаптера
становится failed receipt, отсутствие реализации не выдаётся за успех.

## Интеграция, обновление и откат

Изменения ограничены core/backend; pure codec `24e0043e` предоставлен root.
Compiler имеет необязательные callbacks для host: `DecodeShareLinks(ctx,string)
([]compile.Object,error)`, `CompileRuleSet(ctx,[]byte)(compile.RuleSetResult,error)`
(Behavior, Format, Content []byte — optional MRS) и `DecodeProfile(ctx,string,string)`.
По умолчанию используются pure codec и bounded AGE decoder, runtime не нужен.

Authoring — optional поле существующего profiles.json, без второго хранилища.
Backup config.json включает authoring только при наличии этих данных; restore
атомарно восстанавливает declarations/resources вместе с metadata и sources.
OnlyProfiles также переносит зависимости custom-профилей. data.reset очищает
новые данные и сохраняет migration marker/монотонную ревизию.

Перед откатом бинарника, который ещё не знает поля authoring, нужен сохранённый
предыдущий backend-каталог или восстановление совместимого старого backup:
старый строгий decoder не прочитает расширенный документ. Новый backend читает
старый каталог без миграции и без изменения legacy source/settings semantics.

Host validation проведена на pinned Go 1.27.3 и vendor seed с mihomo 1.19.32.
Интегратор повторяет проверки после объединения с root mihomo 1.19.33 и выполняет
Android ABI cold-start/runtime validation с настоящим isolated validator.
