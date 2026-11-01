# Экспорт ресурсов API v1

## Runtime providers

- Query `provider.inspect {name:string,type:"proxy"|"rule"}` возвращает
  `{format:"text"|"mrs"|"binary",size:int,editable:bool}`. Размер относится к
  исходным bytes. Только UTF-8 text доступен для редактирования; MRS — preview-only.
- Command `provider.export {name,type,asText?:bool}` возвращает обычную асинхронную
  receipt. После успешного завершения `receipt.blob` содержит `{token,size}`;
  bytes читаются через существующий `blob.read`. Повтор operationId возвращает
  тот же результат, не создавая новый transfer.
- Host подключает `Options.ReadProviderResource func(context.Context, string,
  string) ([]byte,error)`, аргументы — имя и вид `proxy`/`rule`. Callback обязан
  разрешать имя через engine и читать не более 16 MiB. UI не передаёт путь.
  Service повторно проверяет размер и context. Отсутствие callback, неизвестный
  provider и ошибка чтения честно возвращаются как ошибки, без fallback к диску.

## Сохранённые authoring resources

Command `authoring.resource.export {collection,id,asText?:bool}` использует тот же
набор сохранённых bytes, что `authoring.resource.read`: contentBase64, иначе
content; для iconSets сохраняется fallback к icons. Допустимые collection:
`scripts`, `clashProviders`, `iconSets`. ID сохраняет существующую семантику
строковых/числовых идентификаторов. Экспорт не изменяет декларацию или runtime.
Remote-ресурс без сохранённых bytes возвращает ошибку; UI должен явно вызвать
`authoring.resource.update` перед повторным экспортом. Сам экспорт не скачивает URL.
Существующий read по-прежнему возвращает пустые bytes для незагруженного ресурса.

## Форматы и ограничения

- `asText` по умолчанию false: исходные bytes выдаются без перекодирования.
- true: чистая `profilecodec.DumpRules([]byte) ([]byte,error)` возвращает UTF-8
  bytes без изменений, MRS Domain/IPCIDR выгружает через mihomo ConvertToMrs
  с MrsRule, остальные binary отклоняет.
- Callback bytes, загрузки ресурсов, сохранённые bytes и экспортируемый blob
  ограничены 16 MiB. Общие blob API сохраняют свои прежние лимиты для backup.
- Для MRS дополнительно ограничены распакованные bytes, окно zstd, длины
  выделений памяти, глубина дерева (4096) и текстовый вывод (16 MiB). Ошибка
  bounded writer проверяется независимо от возвращаемой ошибки mihomo.
- Неизвестные поля (включая path), виды providers и коллекции отклоняются.
  Команды соблюдают существующие cancellation/reset и receipt semantics;
  ошибка экспорта не оставляет частичный blob.

Путь обновления: callback подключается host при открытии backend; API v1 и
существующий transfer transport не меняются. Откат интеграции host удалением
callback оставляет явную ошибку для runtime providers, сохраняя экспорт authoring.

## Android adaptations from FlClashX v0.5.0-pre.6

Source: `50a4067f7b4b6f7019eb11249f3ce8c9580b4071`, compared with
`5b38c0c7dfba726b8335407d0df5e6205e2d9bfa`. Later upstream commits are excluded.

- `ipQuality.get {ip,refresh?:bool}` returns `{quality,checkedAt}`. Go validates
  the IP, queries ipinfo.io with an eight-second deadline, rejects mismatched IPs,
  and retains at most 128 records for 72 hours in private application storage.
  `refresh:true` bypasses the record. Flutter holds only a disposable projection;
  cache failures do not turn a successful lookup into a failed lookup.
- `linkSession.start {}` returns `{sessionId,url,expiresAt}`. This explicit user
  action opens a private IPv4 LAN listener on an ephemeral port for two minutes.
  The 256-bit capability lives in the URL and is never logged. Requests have
  bounded headers/body/deadlines, no external assets, and a same-origin form.
  `linkSession.get {sessionId}` reads one pending link; it never imports it.
  `linkSession.stop {sessionId}`, timeout, backend shutdown, reset, leaving the
  page or backgrounding the UI close the receiver. A stale UI cannot close a
  replacement session. The TV must separately confirm through normal import.
  This authoring service does not start VPN, alter SecurityPolicy or bypass
  subscription import validation. No auto-discovery or permanent listener exists.
- `authoring.copyProxy {name}` is a receipted command. Go reads the applied
  definition by name, reconstructs supported provider overrides, deduplicates and
  chooses a free local name, removes external dialer references, and commits via
  catalog CAS. Built-in transport definitions come from captured original input,
  never from their temporary loopback adapters. Ambiguous provider rewrites fail.
- `engine.command {method:"dns.clear",params:{}}` runs through RuntimeCoordinator;
  it clears resolver caches/connections and advances diagnostic route freshness.
- The Go service reconciles a lost Fallback pin only against the exact applied
  selection, generation and catalog revision. Newer user choices win. Explicit
  embedded transport selections are preserved. Runtime changes remain queued
  through RuntimeCoordinator.

No storage migration is required. Rollback removes these additive APIs and the
UI mounts; the quality cache may be discarded. The old upstream pin remains the
comparison point for unchanged exact base copies; selective tag adaptations are
registered with reasons in the base drift allowlist.

`profile.inspect` дополнительно возвращает `authentication:{enable,username,password}`,
разобранный Go для отображения управляемой подпиской учётной записи. UI хранит
только временную проекцию; сохранённые пользовательские credentials не меняются.
