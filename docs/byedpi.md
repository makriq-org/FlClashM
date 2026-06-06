# byedpi

`byedpi` подключается как встроенный SOCKS5-узел. Отдельных настроек в UI нет:
всё задаётся в конфигурации профиля.

## Автоматический подбор стратегии

```yaml
proxies:
  - name: dpi-auto
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

`strategy-list: byebyeedpi` использует встроенный список из
`romanvht/ByeByeDPI app/src/main/assets/proxytest_strategies.list` под GPL-3.0.
Строка стратегии совместима с ByeByeDPI: это аргументы `ciadpi` без имени
исполняемого файла.

`test.urls` обязателен. Скрытого списка URL для проверки нет.

Клиент не перебирает весь список на старте. Он быстро проверяет первые стратегии
с коротким пределом ответа. Если подходящая стратегия не найдена, включается
запасная: `--disorder 1 --auto=torst --tlsrec 1+s`. Это нужно, чтобы локальный
SOCKS5-узел не оставался закрытым из-за долгого перебора. Выбранная стратегия
кэшируется для холодного старта.

## Ручная стратегия

```yaml
proxies:
  - name: dpi-fixed
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

Клиент сам добавляет `--ip 127.0.0.1` и выделенный `--port`.
Профиль не может задавать `ip`, `port`, `listen` или `server`.
