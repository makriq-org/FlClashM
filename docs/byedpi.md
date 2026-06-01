# byedpi

`byedpi` подключается как скрытый built-in SOCKS5 node. UI не содержит
отдельных настроек: все задается в profile config.

## Auto

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

`strategy-list: byebyeedpi` использует bundled список из
`romanvht/ByeByeDPI app/src/main/assets/proxytest_strategies.list` под
GPL-3.0. Строка стратегии совместима с ByeByeDPI: это аргументы `ciadpi`
без самого имени `ciadpi`.

`test.urls` обязателен. Клиент не имеет скрытого списка URL для проверки.

## Manual

```yaml
proxies:
  - name: dpi-fixed
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

Клиент сам добавляет `--ip 127.0.0.1` и выделенный `--port`.
Профиль не может задавать `ip`, `port`, `listen` или `server`.
