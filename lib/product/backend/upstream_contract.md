# Контракт UI 0.5.0 → Go API v1

Источник: 5b38c0c7dfba726b8335407d0df5e6205e2d9bfa.

Все profileId — строки без преобразования в int или hash. Чтение возвращает
обычный result; запись — стандартную квитанцию с ожиданием operation.get.
Runtime меняется только через Go RuntimeCoordinator. Android :remote и
:validator, внешние процессы транспортов и package com.makriq.flclash сохранены.

## Атомарная проекция конструктора

- authoring.snapshot без params → {revision:int,profiles:[metadata],collections:{scripts:[],rules:[],disabledRules:[],proxyGroups:[],clashProviders:[],customProxies:[],proxyDialers:[],iconRecords:[],iconSets:[]}}. Метаданные и коллекции принадлежат одной revision каталога.
- authoring.replace {expectedRevision:int,collections:object,profiles?:[metadata],deletedProfileIds?:[string]} → receipt с revision:int и optional runtimeOperationId:string. Единственная атомарная запись формы. profiles — upserts в указанном порядке; прочие профили сохраняются. Удаления только явные; исходники и неизвестные metadata сохраняет Go. Последний удалённый профиль вызывает durable Stop. Ошибка последующей компиляции не отменяет сохранение.
- Большие collections передаются как JSON самих collections в blob: вместо collections используется token:string; остальные поля остаются рядом.
- Формат строки коллекции — toJson соответствующей модели апстрима. Ссылки rules/proxyGroups/proxyDialers используют profileId:string|null. scripts.content:string содержит исходный JavaScript; clashProviders.contentBase64:string содержит исходные байты локального набора, пустая строка у remote. disabledRules:{profileId:string,ruleId:int}; proxyDialers:{profileId:string,proxyId:int,target:string}.
- Новые custom-профили задаются metadata.type=custom без source; их собирает Go.

SQL — только NativeDatabase.memory(), без дискового SQLite. Go CAS завершается
до локального SQL commit. Ошибка отменяет SQL draft; восстановление полностью
перестраивает SQL из authoring.snapshot. Отдельных profile.put/delete внутри
commit проекции нет. Flutter не выполняет runtime-компиляцию и не планирует
подписки; временные экспорты редактора не являются источником истины.

## Редактор и импорт

- profile.inspect {profileId:string} → {config:object,outbounds:object,base:object}. config — разобранный исходник, не RuntimePlan. outbounds — upstream {proxies:[],"proxy-groups":[],"proxy-providers":{}}. base — upstream ProfileBase: {config,digest,present,proxies,"proxy-groups",rules,"match-rules"}.
- profile.render {profileId:string,countsOnly?:bool,format?:"yaml"} → receipt.blob:{token:string,size:int}. Go компилирует; UI скачивает blob и удаляет его. При countsOnly blob содержит только числа groups, proxies и rules скомпилированного профиля. При format: "yaml" возвращается многострочный YAML с сохранением порядка вложенных полей; по умолчанию — JSON.
- profile.validate {token:string,ageSecretKey:string} → {message:string}; пустая строка — успешная проверка. Существующий source/token вызов без ageSecretKey сохраняет старый контракт квитанции.
- authoring.evaluate {script:string,config:object} → {config:object}; только editor preview, не применение runtime.
- authoring.import {expectedRevision:int,profileId?:string,metadata?:object,source?:string,token?:string,ageSecretKey?:string,links?:bool,select?:bool,replace?:bool,providerSources?:{name:blobToken}} → receipt. Go парсит и сохраняет весь импорт одним CAS с ремапом коллизий. UI может показывать локальный preview, но отправляет исходный blob. Платформенные пути не передаются.
- Существующие profile.import.file / profile.export используют blob API; profile.import.url получает metadata (URL внутри metadata.url). Метаданные обычного профиля — profile.put с expectedRevision; выбор — profile.select; подписки — subscription.refresh. Настройки — settings.patch. Резервные копии — backup.export/restore с blob.
- Отправка заголовков устройства разрешена только при отсутствии запрета во всех трёх местах: request.deviceHeaders, metadata.sendDeviceHeaders профиля и корневом settings.sendDeviceHeaders. Go проверяет сохранённые запреты в общем загрузчике подписок для импорта, ручного/фонового обновления и восстановления исходника; отсутствие поля сохраняет прежнее значение по умолчанию true.

## Ресурсы, обслуживание и runtime

- authoring.resource.update {collection:'clashProviders'|'scripts'|'iconSets',id:int} → receipt; Go загружает и обновляет authoring.
- authoring.resource.read {collection,id} → {contentBase64:string,lastModified:string|null,size:int}; метаданные и совместимость проекции. Редактор провайдеров получает содержимое через export.
- provider.inspect {name:string,type:'proxy'|'rule'} → {format:'text'|'mrs'|'binary',size:int,editable:bool}. Имя сохраняется без изменений; UI нормализует ExternalProvider.type (`Proxy`/`Rule`) в нижний регистр. Opaque path используется только как признак наличия cache: Inline/Compatible и записи без path не запрашивают inspect. Ошибка inspect показывается пользователю, а не превращается в binary.
- provider.export {name:string,type:'proxy'|'rule',asText?:bool} → receipt.blob:{token:string,size:int}. Runtime-ресурс открывает Go по имени и типу; платформенные пути UI не читает. MRS раскрывается в текст только для preview, редактируется только editable text.
- authoring.resource.export {collection:'clashProviders'|'scripts'|'iconSets',id:int,asText?:bool} → receipt.blob:{token:string,size:int}. Для явного preview remote provider без contentBase64 UI сначала вызывает authoring.resource.update; фоновый просмотр списка не скачивает ресурс.
- Оба export ожидаются через BackendClient.command, затем download(token,size); blob.delete выполняется в finally, в том числе при ошибках чтения/декодирования. Если export завершился, но обновление снимка упало, blob удаляется из сохранённой квитанции. Ошибка cleanup не скрывает исходную ошибку чтения.
- provider.sideload остаётся engine.command с params:{name:string,data:string}: Go SideUpdate сохраняет cache. UI не выполняет дополнительную запись File; имя не подменяется id или путём. Старые controller.dumpRuleSet/compileRuleSet больше не участвуют в редакторах.
- storage.clearCache {} → receipt; storage.collect {} → receipt; profile.clearCache {profileId:string} → receipt. Backend проводит cache.clear / cache.collect через координатор.
- data.reset {} — полный сброс. backup.restore поддерживает onlyProfiles и replace.
- runtime.start/stop/apply/restart и proxy.select остаются Go API v1. engine.command использует {method,params}: connection.close,connections.close,connections.reset,traffic.reset,provider.refresh,provider.sideload,geo.update.

## Android helper transport

/service.invokeAction использует старый envelope {id,method,data} → String
ActionResult {id?,method?,code,data}; /core.invokeMethod возвращает UTF8 bytes
того же ActionResult. init({eventEncoding:'utf8'}) включает bytes events;
совместимый bridge использует стандартные String events.

Read-only helpers: probe, outboundIp, serviceCheck, watchRoute(bool),
getConnectionCount, getMemoryStats, encodeShareLinks, decodeShareLinks,
validateProxies, validateFilters. watchRoute → {"core-epoch","picks-version",picks}.
getProxies legacy map адаптируется в {proxies,all}; getConnections legacy
{connections:[]} — в список. DNS и routeChanged events — upstream shapes.
