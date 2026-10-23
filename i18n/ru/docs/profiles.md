# 🧩 Настройка профиля

[← README](../../../README.md) · **Русский** · [English](../../en/docs/profiles.md) · [中文](../../zh/docs/profiles.md) · [فارسی](../../fa/docs/profiles.md)

Готовую подписку достаточно импортировать в приложение. Этот справочник нужен, если вы редактируете YAML или готовите подписку для других.

[Узлы](#nodes) · [Спящий резерв](#activation) · [Проверка](#checks) · [Приложения](#apps) · [Заголовки подписки](#headers)

## 🚀 Минимальный профиль

```yaml
proxies:
  - name: dpi-auto
    type: byedpi
proxy-groups:
  - name: main
    type: select
    proxies: [dpi-auto, DIRECT]
rules:
  - MATCH,main
```

Встроенные узлы задаются в `proxies` и участвуют в обычных группах и правилах mihomo. Локальные адреса, порты и файлы назначает приложение. Удалённые `server` и `port` NaiveProxy задаются в профиле.

<a id="nodes"></a>

## 🔌 Встроенные узлы

UDP поддерживает только ByeDPI; у него UDP включён по умолчанию и отключается через `udp: false`. NaiveProxy, OlcRTC и StormDNS работают без UDP.

### NaiveProxy

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

Обязательны `name`, `type`, `server`, `port`, `username`, `password`. `transport`: `https` по умолчанию или `quic`. Дополнительно: `insecure-concurrency` (1–4), `tunnel-timeout`, `idle-timeout`, `post-quantum`, `headers`, `host-resolver-rules`. Старое поле `proxy`, локальный `listen`, диагностические файлы, цепочки и неизвестные поля отклоняются.

### ByeDPI

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    strategies:
      - builtin:byebyeedpi
      - "--disorder 1"
      - "https://example.org/byedpi-strategies.txt"
```

`mode: auto` перебирает стратегии и сохраняет рабочую отдельно для каждой физической сети (до 16 сетей, без доступа к SSID). По истечении стартового бюджета используется fallback, подбор продолжается в фоне. Проверенный результат и fallback хранятся отдельно. `mode: manual` использует `strategy`; без `mode` наличие `strategy` выбирает manual, иначе auto.

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    strategy: "--disorder 1 --auto=torst --tlsrec 1+s"
```

HTTPS-список содержит одну стратегию на строку; пустые строки и строки с `#` пропускаются. Поддерживается `{sni}`. Ограничения загрузки такие же, как у списков резольверов ниже. `strategy-test` используется только для подбора и не заменяет `connectivity-check`; старое поле `test` не поддерживается.

<details>
<summary>Параметры автоподбора</summary>

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `strategies` | `[builtin:byebyeedpi]` | Встроенные наборы, inline-стратегии и публичные HTTPS-списки в общем порядке |
| `strategy-test.urls` | встроенный endpoint YouTube | Адреса для подбора |
| `strategy-test.sni` | — | Имя хоста для подстановки `{sni}` |
| `strategy-test.dns-resolver` | `https://1.1.1.1/dns-query` | DoH-резолвер адреса проверки; `system` — системный резолвер |
| `strategy-test.timeout` | `5s` | Таймаут одной проверки |
| `strategy-test.requests` | `1` | Запросов на стратегию |
| `strategy-test.request-concurrency` | `4` | Параллельных HTTP-запросов внутри кандидата |
| `strategy-test.min-success-ratio` | `1.0` | Минимальная доля успешных запросов |
| `strategy-selection.strategy-concurrency` | `4` | Одновременно проверяемых стратегий |
| `strategy-selection.startup-timeout` | `15s` | Бюджет подбора до запуска узла |
| `strategy-selection.continue-in-background` | `true` | Продолжать список в фоне после fallback |
| `strategy-selection.fallback-strategy` | — | Временная стратегия, если подбор не успел |
| `strategy-selection.retry-after` | `5m` | Пауза перед новым подбором после fallback |
| `strategy-selection.cache.ttl` | `7d` | Время жизни кэша |
| `strategy-selection.cache.recheck-after` | `1d` | Интервал повторной проверки |
| `strategy-selection.cache.failure-threshold` | `2` | Число ошибок до сброса кэша |

</details>

### OlcRTC

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    provider: jitsi
    room: "https://meet.example.org/room"
    encryption-key: "<64-hex-key>"
    transport: datachannel
    dns-server: "1.1.1.1:53"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

Работает только как CNC-клиент. Замените `<64-hex-key>` ключом сервера из 64 hex-символов. Для `provider: none` обязательны `engine`, `engine-url`, `engine-token`; с другими провайдерами они запрещены. `profiles`, `failover`, `video.hw`, локальные listeners и ключи из файлов запрещены.

`dns-server: system` использует первый DNS физической сети Android и обновляет активный узел при его изменении. Без системного DNS запуск ждёт обновления сети. Клиент и сервер должны поддерживать OLC2 и OLVC 5.

<details>
<summary>Поля и транспорт OlcRTC</summary>

| Параметр | Описание |
|----------|----------|
| `provider` | Поставщик соединения: `jitsi`, `telemost`, `wbstream`, `none` |
| `room` | URL или идентификатор комнаты |
| `encryption-key` | 256-битный ключ — **ровно 64 hex-символа** |
| `transport` | `datachannel`, `vp8channel`, `seichannel`, `videochannel` |
| `dns-server` | Обязательный DNS-сервер в формате `адрес:порт` или `system` |
| `transport-options` | Необязательные параметры выбранного транспорта; для `datachannel` секция запрещена |

`transport-options` для `datachannel` запрещён. Для `vp8channel`: `fps: 30`, `batch-size: 64`; для `seichannel` дополнительно `fragment-size: 900`, `ack-timeout: 2s`. У `videochannel`: `codec` (`qrcode`/`tile`), `width`, `height`, `fps`, `fragment-size`, `qr-recovery`, `tile-module`, `tile-rs`. По умолчанию `qrcode`, 1920×1080, `qr-recovery: low`; для tile — 1080×1080. Старый `bitrate` принимается, но игнорируется.

```yaml
transport: seichannel
transport-options:
  fps: 30
  batch-size: 64
  fragment-size: 900
  ack-timeout: 2s
```

</details>

### StormDNS

```yaml
proxies:
  - name: "storm"
    type: stormdns
    domains: ["v.example.com"]
    encryption: chacha20
    encryption-key: "<key>"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "storm"]
```

`domains`, `encryption`, `encryption-key` обязательны, без значений по умолчанию, и должны совпадать с сервером. `none` и `xor` не скрывают содержимое от оператора резольвера. Первый запуск сканирует резольверы и может занять до двух минут.

<details>
<summary>Резольверы и кэш</summary>

| Параметр | Описание |
|----------|----------|
| `domains` | Домены, делегированные на сервер StormDNS |
| `encryption` | `none`, `xor`, `chacha20`, `aes-128-gcm`, `aes-192-gcm`, `aes-256-gcm` |
| `encryption-key` | Общий ключ; должен совпадать с серверным |

Пустой или отсутствующий `resolvers` означает `[system]`. Источники раскрываются по порядку; дубликаты удаляются по IP с сохранением первого порта. Пустой результат отклоняется. CIDR из профиля ограничен 65536 адресами.

| Элемент | Что добавляет |
|---------|---------------|
| `system` | DNS физической сети (не VPN) |
| `8.8.8.8` | Один резольвер на порту 53 |
| `1.1.1.1:5353` | Один резольвер на своём порту |
| `192.168.1.0/30` | CIDR: у IPv4 сетевой и широковещательный адреса не берутся; диапазон шире 65536 адресов отклоняется |
| `https://…` | Резольверы из удалённого списка |

Не более 32 HTTPS-списков на профиль, без credentials/fragment и локальных адресов сервера загрузки; приватные IP/CIDR внутри списка допустимы. Лимиты ответа: 1 МиБ, 15 с; редиректы запрещены. При сбое берётся прежний кэш даже после `refresh`, без кэша источник пропускается. `refresh` проверяется при применении профиля.

| `resolver-policy` | По умолчанию | Описание |
|-------------------|--------------|----------|
| `refresh` | `24h` | Как часто обновлять удалённые списки |
| `strategy` | `least-loss` | `random`, `round-robin`, `least-loss`, `lowest-latency` |
| `auto-disable` | `true` | Отключать резольверы, которые перестали отвечать |
| `recheck` | `true` | Периодически перепроверять отключённые |

| `startup.mode` | Что делает |
|----------------|------------|
| `scan` | Полное сканирование резольверов (самый медленный старт) |
| `cached` (по умолчанию) | Старт из кэша без перепроверки MTU |
| `verified` | Старт из кэша с перепроверкой MTU |

Кэш зависит от резольверов, `domains` и версии StormDNS. `startup.max-age` — целое число дней, по умолчанию `30d`. Без подходящего кэша выполняется сканирование. Смена системного DNS сбрасывает MTU-кэш и перезапускает активные зависимые узлы без UI. Локальные DNS/SOCKS, resolver-файл, журнал и `startup.mode: ask` в профиле запрещены.

</details>

<details>
<summary>Пресеты и точная настройка</summary>

Порядок: defaults → `preset` → явные поля. Длительности задаются строками с единицей (`600ms`, `30s`, `24h`, `30d`). Выход за границы отклоняется до запуска.

| `preset` | Дублирование (upload / download / upload-setup / download-setup) | Сжатие |
|----------|------------------------------------------------------------------|--------|
| `messenger` (по умолчанию) | 1 / 7 / 3 / 8 | `lz4` |
| `balanced` | 2 / 5 / 3 / 6 | `lz4` |
| `bulk` | 3 / 3 / 4 / 4 | `zstd` |

```yaml
preset: bulk
duplication:
  upload: 2
compression:
  upload: zlib
```

| Блок | Поля и границы |
|------|----------------|
| `duplication` | `upload`, `download`, `upload-setup`, `download-setup` — 1…8 |
| `compression` | `upload`, `download` — `none`, `zstd`, `lz4`, `zlib`; `min-size` — 100…65535 |
| `mtu.upload`, `mtu.download` | `min` — 1…65535; `max` — 0…65535, где `0` снимает верхнюю границу |
| `arq` | `window` 1…6000, `nack-max-gap` 0…1500, `max-control-retries` 5…5000, `max-data-retries` 60…100000; остальные поля — длительности |
| `ping` | только длительности: интервалы `aggressive`/`lazy`/`cooldown`/`cold` и пороги `warm`/`cool`/`cold` |
| `runtime` | `workers` и `process-workers` 1…64, размеры очередей и пулов, длительности повторов; `base-encode` — флаг |

Связанные ограничения проверяются целиком:

- `duplication.upload-setup` ≥ `upload`, `download-setup` ≥ `download`
- `mtu.<направление>.max` ≥ `min`
- `arq.initial-rto` ≤ `max-rto`, `arq.control-initial-rto` ≤ `control-max-rto`
- `arq.nack-max-gap` ≤ `arq.window / 4`
- `ping.aggressive-interval` ≤ `lazy-interval` ≤ `cooldown-interval` ≤ `cold-interval`
- `ping.warm-threshold` ≤ `cool-threshold` ≤ `cold-threshold`
- `runtime.process-workers` ≥ `runtime.workers`
- `runtime.session-retry-base` ≤ `session-retry-max`

Имена полей совпадают с конфигом StormDNS.

</details>

<a id="activation"></a>

## 😴 Спящий резерв

OlcRTC и StormDNS по умолчанию используют `activation: auto`: запускаются при ручном выборе или отказе наблюдаемой группы. Узел должен напрямую входить в группу. Без выбора и соединений он засыпает после `sleep.idle`; `0s` запрещает сон до перезапуска VPN. Для запуска вместе с профилем задайте `activation: always`.

```yaml
activation:
  mode: auto
  wake:
    urls: ["https://example.org/generate_204"]
    interval: 30s
    failures: 2
    retry-after: 5m
  sleep:
    idle: 15m
```

<details>
<summary>Параметры пробуждения и сна</summary>

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `mode` | `auto` | `auto` усыпляет резерв; `always` — прежний постоянный запуск |
| `wake.urls` | цепочка `connectivity-check` | Публичные HTTP(S)-адреса для проверки наблюдаемой группы |
| `wake.interval` | `30s` | Интервал проверки во сне |
| `wake.failures` | `2` | Неудачных раундов подряд до пробуждения |
| `wake.retry-after` | `5m` | Пауза после неудачного запуска |
| `sleep.idle` | `15m` | Время без соединений и выбора до сна; `0s` — не засыпать до перезапуска VPN |

</details>

<a id="checks"></a>

## 🩺 Проверка доступности

Всегда проверяются процесс и SOCKS-порт. HTTP(S)-адрес выбирается из `connectivity-check.urls` узла, ближайшей группы или общего URL приложения. `required: false` выполняет проверку в фоне; `true` требует адрес и отменяет запуск с откатом при неудаче. Любой корректный HTTP-ответ, включая 4xx/5xx, считается успехом.

```yaml
connectivity-check:
  urls: ["https://example.org/generate_204"]
  required: true
```

Разрешены только публичные HTTP(S)-адреса без credentials/fragment. DNS проверяется перед запросом; соединение идёт через SOCKS проверяемого узла, без прямого fallback. TLS проверяет исходное имя.

<details>
<summary>Все параметры проверки</summary>

| Поле | По умолчанию | Что задаёт |
|------|--------------|-----------|
| `urls` | — | Адреса для проверки (публичные HTTP(S), без учётных данных и фрагментов) |
| `required` | `false` | Обязательна ли проверка для запуска |
| `timeout` | `5s` | Таймаут одного запроса |
| `startup-timeout` | `30s` (у `stormdns` — `2m`) | Общий бюджет проверки при запуске |
| `retry-interval` | `1s` | Пауза между попытками |
| `requests` | `1` | Сколько запросов сделать |
| `concurrency` | `1` | Сколько запросов параллельно |
| `min-success-ratio` | — | Минимальная доля успешных ответов (без неё достаточно одного) |

</details>

<a id="apps"></a>

## 🎯 Какие приложения идут через VPN

Правила профиля приоритетнее ручных настроек. `include-package` направляет через VPN только указанные приложения, `exclude-package` — все остальные. Их нельзя задавать одновременно; явный пустой список отличается от отсутствия правила.

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

| Формат | Пример | Что означает |
|--------|--------|--------------|
| 🎯 Точное имя | `com.termux` | Точное совпадение пакета |
| ✳️ Маска | `*.yandex.*` | Все приложения Яндекса |
| 🔤 Регулярка | `re:^org\.mozilla\..+$` | Все приложения Mozilla |
| 🚫 Исключение | `!ru.yandex.browser` | Убрать из списка |

`include-package-url` / `exclude-package-url` принимают HTTP(S)-списки: один пакет или селектор на строку. Прежний кэш используется без сети; подписки и списки приложений могут размещаться на приватных серверах. Локальные `include-package-file` / `exclude-package-file` на Android игнорируются с записью в журнал.

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

При работающем VPN интерфейс показывает правила последнего успешного создания туннеля. Перезагрузка mihomo сама по себе их не меняет. Если снимок недоступен, UI явно показывает декларацию профиля вместо подтверждённого состояния.

<a id="headers"></a>

## 🎨 Заголовки подписки

HTTP-ответ подписки содержит YAML в теле и подсказки в заголовках. Поддерживаются `flclashm-*` и совместимые `flclashx-*`; первый префикс приоритетнее. Булевы значения — `true`/`false`.

```text
flclashm-custom: update
flclashm-hex: 5c6bc0:vibrant:pureblack
flclashm-view: type:tab;sort:delay;card:min
flclashm-settings: autostart,autoupdate
```

`flclashm-custom: add` применяет оформление при добавлении, `update` — при каждом обновлении; без них оформление не применяется. Ручные настройки пользователя приоритетнее `flclashm-settings`. `androidsecure` отключает только mixed-port, не меняя выбор VPN. Поля `flclashm-override` / `flclashx-override` поддерживаются в группе `GLOBAL`, приоритет у первого.

<details>
<summary>Справочник заголовков и форматов</summary>

| Заголовок | Значение | Назначение |
|---|---|---|
| `flclashm-background` | `URL` | Фоновое изображение |
| `flclashm-hex` | `HEX[:variant][:pureblack]` | Цветовая тема |
| `flclashm-widgets` | `list` | Порядок виджетов |
| `flclashm-view` | `key:value;…` | Вид страницы узлов |
| `flclashm-newboard` | `true/false` | Новая панель |
| `flclashm-denywidgets` | `true/false` | Запрет редактирования дашборда |
| `flclashm-servicename` | `base64` | Название сервиса |
| `flclashm-servicelogo` | `base64(URL)` | Логотип сервиса |
| `flclashm-serverinfo` | `base64` | Имя группы информации о сервере |
| `flclashm-buyplan` | `URL` | Продление подписки |
| `flclashm-buytraffic` | `URL` | Покупка трафика |
| `flclashm-settings` | `autostart,autoupdate,…` | Настройки, разделённые запятой |
| `flclashm-globalmode` | `false` | Скрыть выбор global |
| `flclashm-androidsecure` | `true` | Отключить mixed-port на Android |
| `flclashm-custom` | `add/update` | Когда применять оформление |
| `announce` | `text/base64:…` | Объявление |
| `support-url` | `URL` | Поддержка |
| `x-hwid-max-devices-reached` | `—` | Достигнут лимит устройств |
| `x-hwid-not-supported` | `—` | HWID не поддерживается |

`flclashm-hex`: цвет из 6/8 hex-символов с необязательным `#`, затем вариант Material 3 и `pureblack`. Варианты: `tonalSpot`, `fidelity`, `monochrome`, `neutral`, `vibrant`, `expressive`, `content`, `rainbow`, `fruitSalad`.

Пары `flclashm-view` разделяются `;`; все ключи необязательны:

| Ключ | Допустимые значения |
|------|---------------------|
| `type` | `list`, `tab` |
| `sort` | `none`, `delay`, `name` |
| `layout` | `loose`, `standard`, `tight` |
| `icon` | `icon` (или `standard`), `none` |
| `card` | `expand`, `shrink`, `min`, `oneline` |

Флаги `flclashm-settings`:

| Флаг | Что включает |
|------|--------------|
| `autostart` | Автозапуск/автоподключение (в т. ч. после перезагрузки) |
| `autoupdate` | Автоматическую проверку обновлений |
| `autorun` | Запуск приложения при старте системы *(desktop)* |
| `shadowstart` | Тихий (фоновый) запуск |
| `minimize` | Сворачивание в трей при выходе *(desktop)* |

</details>
