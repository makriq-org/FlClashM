# Runtime

## Processing pipeline

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan
```

After that, the lifecycle is managed by `EngineManager` and `EngineAdapter`.

## Built-in nodes

Built-in nodes are defined as regular proxies in the profile. Their lifecycle is managed by `BuiltInProxySupervisor`.

### naiveproxy

- **Type:** `naiveproxy`
- **Required fields:** `name`, `type`, `server`, `port`, `username`, `password`
- Only `https` and `quic` transports are allowed; anonymous access is rejected
- UDP is unsupported; the resulting local Mihomo node uses `udp: false`
- The client chooses the local SOCKS5 address automatically
- The compiler escapes credentials, builds one internal URI, and launches
  NaiveProxy with an auto-generated `config.json`
- An allowlist rejects `proxy`, `listen`, diagnostic files, proxy chains, and
  unknown fields

### olcrtc

- **Type:** `olcrtc`
- **Required fields:** `name`, `auth.provider`, `room.id`, `crypto.key`
- Only works in CNC (client) mode
- UDP is unsupported; the resulting local Mihomo node uses `udp: false`

### byedpi

- **Type:** `byedpi`
- **`manual` mode:** accepts an `args` string
- **`auto` mode:** cycles through ByeByeDPI strategies, caches the working one
- Without `mode`, `args` selects manual mode and its absence selects auto mode
- Supports `{sni}` substitution
- UDP is enabled by default and passed to the local Mihomo node; `udp: false`
  disables it, and no UDP argument is passed to the ByeDPI process

## Limitations

- Built-in nodes only work in the `proxies` section
- Local addresses and ports are determined by the client
- ByeDPI in `auto` mode tests `strategy-test.urls` or the bundled YouTube endpoint
