# Встроенные узлы

Встроенные узлы задаются прямо в YAML-профиле и работают как обычные прокси. FlClashM сам запускает нужные процессы и управляет портами.

## ByeDPI

**Тип:** `byedpi`

Поддерживает два режима:

### Автоматический подбор стратегии

Клиент перебирает стратегии из списка ByeByeDPI, находит рабочую и кэширует её.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-list: byebyeedpi
    test:
      urls:
        - "https://example.com/"
      sni: "example.com"
      timeout: 5
      requests: 1
      concurrency: 4
      min-success-ratio: 1.0
    cache:
      ttl: 604800
      recheck-after: 86400
      failure-threshold: 2
```

**Параметры:**

| Параметр | Описание |
|----------|----------|
| `strategy-list` | Имя списка стратегий (`byebyeedpi`) |
| `test.urls` | Адреса для проверки |
| `test.sni` | Имя хоста для подстановки `{sni}` |
| `test.timeout` | Таймаут одной проверки в секундах (по умолчанию 5) |
| `test.requests` | Количество запросов на стратегию (по умолчанию 1) |
| `test.concurrency` | Параллельных проверок (по умолчанию 4) |
| `test.min-success-ratio` | Минимальная доля успешных запросов (по умолчанию 1.0) |
| `cache.ttl` | Время жизни кэша в секундах (по умолчанию 7 дней) |
| `cache.recheck-after` | Интервал повторной проверки в секундах (по умолчанию 1 день) |
| `cache.failure-threshold` | Количество ошибок до сброса кэша (по умолчанию 2) |

Если ни одна стратегия не подошла, используется запасная.

### Ручная стратегия

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

## OlcRTC

**Тип:** `olcrtc`

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    auth:
      provider: jitsi
    room:
      id: "https://meet.example.org/room"
    crypto:
      key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    net:
      transport: datachannel
```

**Параметры:**

| Параметр | Описание |
|----------|----------|
| `auth.provider` | Провайдер аутентификации (`jitsi`, `telemost`) |
| `room.id` | Идентификатор комнаты видеозвонка |
| `crypto.key` | 256-битный ключ шифрования (hex) |
| `net.transport` | Транспорт (`datachannel`, `vp8channel`) |

## NaiveProxy

**Тип:** `naiveproxy`

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

## Ограничения

- Встроенные узлы задаются только в секции `proxies`.
- Клиент сам управляет локальными адресами и портами.
- Профиль не может задавать `listen`, `server`, `port`, `ip`.
- Все встроенные узлы работают только с TCP (`udp: false` всегда).
