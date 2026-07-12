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
- **Required fields:** `name`, `proxy`
- UDP is unsupported; the resulting local Mihomo node uses `udp: false`
- The client chooses the local SOCKS5 address automatically
- Launched with an auto-generated `config.json`

### olcrtc

- **Type:** `olcrtc`
- **Required fields:** `name`, `auth.provider`, `room.id`, `crypto.key`
- Only works in CNC (client) mode
- UDP is unsupported; the resulting local Mihomo node uses `udp: false`

### byedpi

- **Type:** `byedpi`
- **`manual` mode:** accepts an `args` string
- **`auto` mode:** cycles through ByeByeDPI strategies, caches the working one
- Supports `{sni}` substitution
- UDP is enabled by default and passed to the local Mihomo node; `udp: false`
  disables it, and no UDP argument is passed to the ByeDPI process

## Limitations

- Built-in nodes only work in the `proxies` section
- Local addresses and ports are determined by the client
- ByeDPI in `auto` mode only tests URLs from `test.urls`
