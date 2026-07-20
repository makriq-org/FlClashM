# Built-in nodes

Built-in nodes are defined directly in the YAML profile and work like regular proxies. FlClashM launches the required processes and manages ports automatically.

## ByeDPI

**Type:** `byedpi`

UDP is enabled by default. Set `udp: false` on the node to disable it.

Supports two modes:

### Automatic strategy selection

The client cycles through strategies from the ByeByeDPI list, finds a working one, and caches it.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `strategy-list` | Strategy list name (default `byebyeedpi`) |
| `strategies` | Ordered custom strategies instead of `strategy-list` |
| `strategy-test.urls` | Strategy-selection URLs; defaults to the bundled YouTube test endpoint |
| `strategy-test.sni` | Hostname for `{sni}` substitution |
| `strategy-test.timeout` | Timeout per candidate in seconds (default 5) |
| `strategy-test.requests` | Number of requests per URL (default 1) |
| `strategy-test.concurrency` | Parallel HTTP requests within one candidate (default 4) |
| `strategy-test.min-success-ratio` | Minimum success ratio (default 1.0) |
| `selection.concurrency` | Strategies probed at once (default 4) |
| `selection.foreground-timeout` | Total foreground budget in seconds (default 15) |
| `selection.background` | Continue after starting the fallback (default `true`) |
| `fallback-args` | Temporary fallback arguments |
| `cache.ttl` | Cache lifetime in seconds (default 7 days) |
| `cache.recheck-after` | Recheck interval in seconds (default 1 day) |
| `cache.retry-after` | Cooldown after a provisional fallback (default 5 minutes) |
| `cache.failure-threshold` | Errors before cache invalidation (default 2) |

Candidates are probed in bounded parallel batches. When the foreground budget
expires, the fallback starts immediately and the remaining list continues in the
background. Any valid HTTP response from the server, including `4xx` and `5xx`,
counts as success. A provisional fallback is never treated as a verified result.
Without `mode`, nodes with `args` use manual mode and all other nodes use auto
mode. `strategy-test.urls` overrides the bundled test endpoint and remains
separate from `connectivity-check`.

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

UDP is not supported; only `udp: false` is allowed.

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

UDP is not supported; only `udp: false` is allowed.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

Required fields: `name`, `type`, `server`, `port`, `username`, and `password`.
`transport` defaults to `https`; `quic` is also allowed. Optional settings are
`insecure-concurrency` (1–4), `tunnel-timeout`, `idle-timeout`, `post-quantum`,
the `headers` map, `host-resolver-rules`, and the common `connectivity-check`.

The client safely builds a URI with escaped credentials for NaiveProxy and
replaces the Mihomo node with a local SOCKS5 proxy. The old `proxy` field is not
supported. `listen`, diagnostic files, proxy chains, and unknown fields are
rejected during profile validation.

## Limitations

- Built-in nodes can only be defined in the `proxies` section.
- The client manages local addresses and ports automatically.
- The profile cannot set a local `listen`; NaiveProxy `server` and `port`
  describe only the remote server.
- ByeDPI uses UDP by default and allows it to be disabled with `udp: false`.
  NaiveProxy and OlcRTC do not support UDP.
