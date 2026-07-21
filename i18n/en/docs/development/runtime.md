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

With `activation.mode: auto`, the supervisor stages OlcRTC artifacts but omits a
sleeping reserve from both live and cold-start manifests. Its mandatory
end-to-end check therefore no longer gates VPN startup. The watchdog probes the
watched group, wakes the reserve after the configured failures, atomically
reapplies the full plan, and forces a delay test of OlcRTC itself. After the idle
period has no matching connection chains and no directly containing group
selects the node, the plan is reapplied without it. Profile switches and stops
cancel transitions with a generation token; sleep state is intentionally not
persisted.

Mihomo and network access cross the app boundary through `RuntimeHealthProbe`,
which exposes only delay tests, active connection chains, group `now` values,
and device-network availability. The app-layer implementation uses `clashCore`
and `connectivity_plus`. Without an injected probe the automatic watchdog stays
idle, while staging, stopping, and manual wake remain safe. `always` mode keeps
the original startup transaction unchanged.

This integration ships with the app's Dart layer and does not change the Android
bridge. `activation: always` is the operational rollback, and a version rollback
requires no state migration.

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
