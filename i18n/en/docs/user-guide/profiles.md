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
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `auth.provider` | Auth provider (`jitsi`, `telemost`, `wbstream`, `none`) |
| `room.id` | Video call room identifier |
| `crypto.key` | 256-bit encryption key: exactly 64 hexadecimal characters |
| `net.transport` | Transport (`datachannel`, `vp8channel`, `seichannel`, `videochannel`) |
| `net.dns` | Required DNS resolver in `host:port` format |

### Activation

OlcRTC is a reserve node by default: its configuration is prepared in advance,
but the process sleeps until the primary group probe fails or the user selects
OlcRTC manually. Shorthand form:

```yaml
activation: auto
# activation: always  # old behavior: start together with the VPN
```

Full form:

```yaml
activation:
  mode: auto
  wake:
    urls: ["https://example.org/generate_204"]
    interval: 30
    failures: 2
    retry-after: 300
  sleep:
    idle: 900
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `mode` | `auto` | `auto` keeps the reserve asleep; `always` restores permanent startup |
| `wake.urls` | `connectivity-check` chain | Public HTTP(S) addresses used to probe the watched group |
| `wake.interval` | `30` | Seconds between watchdog rounds while asleep |
| `wake.failures` | `2` | Consecutive failed rounds required to wake |
| `wake.retry-after` | `300` | Backoff in seconds after a failed wake attempt |
| `sleep.idle` | `900` | Seconds without traffic or selection before sleep; `0` keeps it awake until VPN restart |

In `auto` mode the node must be a direct member of at least one proxy group, and
probe addresses must resolve from `wake.urls`, the node's `connectivity-check`,
the nearest containing group, or the application's global test URL. After wake,
the client immediately tests OlcRTC itself. It stops the process again after no
containing group selects it and no active connection uses it for `sleep.idle`;
manual selection wakes it immediately.

`auto` is now the default even when `activation` is omitted. Set
`activation: always` to restore the previous always-on behavior exactly.

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
