# Built-in nodes

Built-in nodes are defined directly in the YAML profile and work like regular proxies. FlClashM launches the required processes and manages ports automatically.

## ByeDPI

**Type:** `byedpi`

Supports two modes:

### Automatic strategy selection

The client cycles through strategies from the ByeByeDPI list, finds a working one, and caches it.

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

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `strategy-list` | Strategy list name (`byebyeedpi`) |
| `test.urls` | URLs to test |
| `test.sni` | Hostname for `{sni}` substitution |
| `test.timeout` | Timeout per test in seconds (default 5) |
| `test.requests` | Number of requests per strategy (default 1) |
| `test.concurrency` | Parallel tests (default 4) |
| `test.min-success-ratio` | Minimum success ratio (default 1.0) |
| `cache.ttl` | Cache lifetime in seconds (default 7 days) |
| `cache.recheck-after` | Recheck interval in seconds (default 1 day) |
| `cache.failure-threshold` | Errors before cache invalidation (default 2) |

If no strategy works, a fallback is used.

### Manual strategy

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

## OlcRTC

**Type:** `olcrtc`

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
      dns: "1.1.1.1:53"
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `auth.provider` | Auth provider (`jitsi`, `telemost`, `wbstream`, `none`) |
| `room.id` | Video call room identifier |
| `crypto.key` | 256-bit encryption key: exactly 64 hexadecimal characters |
| `net.transport` | Transport (`datachannel`, `vp8channel`, `seichannel`, `videochannel`) |
| `net.dns` | Required DNS resolver in `host:port` format |

## NaiveProxy

**Type:** `naiveproxy`

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

## Limitations

- Built-in nodes can only be defined in the `proxies` section.
- The client manages local addresses and ports automatically.
- The profile cannot set `listen`, `server`, `port`, `ip`.
- All built-in nodes only work with TCP (`udp: false` always).
