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
