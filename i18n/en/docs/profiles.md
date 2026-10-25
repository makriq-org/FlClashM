# 🧩 Profile setup

[← README](../README.md) · [Русский](../../ru/docs/profiles.md) · **English** · [中文](../../zh/docs/profiles.md) · [فارسی](../../fa/docs/profiles.md)

Import a subscription into the app to use an existing configuration. This reference is for editing YAML or preparing a subscription for others.

[Nodes](#nodes) · [Sleeping reserve](#activation) · [Checks](#checks) · [Apps](#apps) · [Subscription headers](#headers)

## Profile builder and editor

Create a profile in the app from nodes, groups and rules without a source YAML file. Shared resources and scripts are available in configuration; local rule lists can be imported, previewed and edited. MRS supports a text preview while preserving its original bytes.

Imported profiles support YAML editing, overrides and a preview of the resulting configuration. Script previews do not change the running connection. The background service saves changes, so closing the interface does not interrupt the connection or subscription updates.

Save a backup before upgrading. After saving new profiles or resources, older app versions may be unable to open the updated storage. Downgrading requires a backup made by the older version; it will not include later changes.

## 🚀 Minimal profile

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

Built-in nodes belong in `proxies` and work with ordinary mihomo groups and rules. The app assigns local addresses, ports and files. NaiveProxy’s remote `server` and `port` belong in the profile.

<a id="nodes"></a>

## 🔌 Built-in nodes

Only ByeDPI supports UDP; it is enabled by default and can be disabled with `udp: false`. NaiveProxy, OlcRTC and StormDNS do not support UDP.

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

Required: `name`, `type`, `server`, `port`, `username`, `password`. `transport`: `https` by default, or `quic`. Optional: `insecure-concurrency` (1–4), `tunnel-timeout`, `idle-timeout`, `post-quantum`, `headers`, `host-resolver-rules`. Legacy `proxy`, local `listen`, diagnostic files, chains and unknown fields are rejected.

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

`mode: auto` tries strategies and caches a result per physical network (up to 16 networks, without SSID access). After the startup budget, a fallback is used while selection continues in the background. The cache marks the result as verified or temporary; fallback uses its own `retry-after`. `mode: manual` uses `strategy`; without `mode`, a `strategy` selects manual, otherwise auto.

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    strategy: "--disorder 1 --auto=torst --tlsrec 1+s"
```

HTTPS lists contain one strategy per line; empty lines and lines starting with `#` are ignored. `{sni}` is supported. Download limits match the resolver lists below. `strategy-test` is only for selection and does not replace `connectivity-check`; legacy `test` is unsupported.

<details>
<summary>Automatic selection parameters</summary>

| Parameter | Default | Description |
|-----------|---------|-------------|
| `strategies` | `[builtin:byebyeedpi]` | Built-ins, inline strategies, and public HTTPS lists in one order |
| `strategy-test.urls` | built-in YouTube endpoint | Addresses for selection |
| `strategy-test.sni` | `google.com` | Hostname to substitute for `{sni}` |
| `strategy-test.dns-resolver` | `https://1.1.1.1/dns-query` | DoH resolver for the test address; `system` uses the system resolver |
| `strategy-test.timeout` | `5s` | Per-check timeout |
| `strategy-test.requests` | `1` | Requests per strategy |
| `strategy-test.request-concurrency` | `4` | Parallel HTTP requests inside a candidate |
| `strategy-test.min-success-ratio` | `1.0` | Minimum fraction of successful requests |
| `strategy-selection.strategy-concurrency` | `4` | Strategies checked at once |
| `strategy-selection.startup-timeout` | `0s` | Selection budget before the node starts |
| `strategy-selection.continue-in-background` | `true` | Keep checking the list in the background after fallback |
| `strategy-selection.fallback-strategy` | built-in strategy | Temporary strategy if selection did not finish in time |
| `strategy-selection.retry-after` | `5m` | Pause before a new selection after fallback |
| `strategy-selection.cache.ttl` | `7d` | Cache lifetime |
| `strategy-selection.cache.recheck-after` | `1d` | Re-check interval |
| `strategy-selection.cache.failure-threshold` | `2` | Errors before the cache is reset |

With `0s`, the node starts immediately with the cached or fallback strategy and selection continues in the background. Without background selection, the default budget is `15s`.

</details>

<a id="olcrtc"></a>

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

CNC client mode only. Replace `<64-hex-key>` with the server key: exactly 64 hexadecimal characters. `provider: none` requires `engine`, `engine-url`, `engine-token`; other providers reject them. `profiles`, `failover`, `video.hw`, local listeners and keys from files are forbidden.

`dns-server: system` uses the first DNS server of Android’s physical network: `host:53` for IPv4, `[IPv6]:53` for IPv6. Changes restart the active dependent node. If DNS is unavailable, startup immediately fails with `physical DNS is unavailable`. A launch failure during plan application aborts that application; a failed background wake uses `retry-after`. Client and server must support OLC2 and OLVC 5.

The bundled runtime is the [Ghostlane fork](https://github.com/ghostlane-project/olcrtc).
Use these combinations for the new services:

| `provider` | `transport` | `room` | Additional requirements |
|---|---|---|---|
| `vkcalls` | `vp8channel` or `videochannel` | `https://vk.ru/call/join/<id>` | VK call join link; non-empty `provider-token` is forbidden |
| `mtslink` | `vp8channel` | `https://my.mts-link.ru/j/<owner>/<event>` | Permanent MTS Link meeting |
| `salutejazz` | `datachannel` | `<code>:<password>` | SaluteJazz room code and password |
| `max` | `datachannel` | `https://max.ru/joincall/<hash>` | Required `provider-token`: MAX calls session key or calls token |

The token is passed only to the OlcRTC process in its private config; do not publish profiles containing it.
Unsupported provider/transport combinations are rejected before the process starts.

<details>
<summary>OlcRTC fields and transport</summary>

| Parameter | Description |
|-----------|-------------|
| `provider` | Connection provider: `jitsi`, `telemost`, `wbstream`, `salutejazz`, `vkcalls`, `mtslink`, `max`, `none` |
| `room` | Room URL or ID; required except for `provider: none` |
| `encryption-key` | 256-bit encryption key — **exactly 64 hex characters** |
| `transport` | Transport: `datachannel`, `vp8channel`, `seichannel`, `videochannel` |
| `dns-server` | Required `host:port` or `system` |
| `transport-options` | Optional settings for the selected transport; forbidden for `datachannel` |

`transport-options` is forbidden for `datachannel`. `vp8channel` defaults: `fps: 30`, `batch-size: 64`; `seichannel` adds `fragment-size: 900`, `ack-timeout: 2s`. `videochannel` accepts `codec` (`qrcode`/`tile`), `width`, `height`, `fps`, `fragment-size`, `qr-recovery`, `tile-module`, `tile-rs`. Defaults: `qrcode`, 1920×1080, `qr-recovery: low`; tile uses 1080×1080. Legacy `bitrate` is accepted but ignored.

```yaml
proxies:
- name: rtc
  type: olcrtc
  provider: jitsi
  room: https://meet.example.org/room
  encryption-key: "<64-hex-key>"
  transport: seichannel
  dns-server: 1.1.1.1:53
  transport-options:
    fps: 30
    batch-size: 64
    fragment-size: 900
    ack-timeout: 2s
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - rtc
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

`domains`, `encryption`, `encryption-key` are required, have no defaults and must match the server. `none` and `xor` do not hide content from the resolver operator. The first startup scans resolvers and can take up to two minutes.

<details>
<summary>Resolvers and cache</summary>

| Field | Description |
|-------|-------------|
| `domains` | Domains delegated to the StormDNS server |
| `encryption` | `none`, `xor`, `chacha20`, `aes-128-gcm`, `aes-192-gcm`, `aes-256-gcm` |
| `encryption-key` | Shared key; must match the server |

An empty or missing `resolvers` means `[system]`. Sources expand in order; duplicates are removed by IP, keeping the first port. An empty result is rejected. Profile CIDRs are limited to 65536 addresses.

| Entry | What it adds |
|-------|--------------|
| `system` | DNS servers of the physical (non-VPN) network |
| `8.8.8.8` | One resolver on port 53 |
| `1.1.1.1:5353` | One resolver on its own port |
| `192.168.1.0/30` | CIDR up to 65536 addresses. IPv4 ranges with more than 2 addresses exclude first and last; `/31` and `/32` are kept in full. IPv6 ranges with more than 2 addresses exclude the first |
| `https://…` | Resolvers from a remote list |

At most 32 HTTPS lists per profile, without credentials/fragment or local download-server addresses; private IPs/CIDRs inside a list are allowed. Response limits: 1 MiB, 15 seconds; redirects are forbidden. On failure, the previous cache is used even after `refresh`; without a cache the source is skipped. `refresh` is checked when applying a profile.

| `resolver-policy` | Default | Description |
|-------------------|---------|-------------|
| `refresh` | `24h` | How often remote lists are refreshed |
| `strategy` | `least-loss` | `random`, `round-robin`, `least-loss`, `lowest-latency` |
| `auto-disable` | `true` | Disable resolvers that stop answering |
| `recheck` | `true` | Periodically re-test disabled resolvers |

| `startup.mode` | What it does |
|----------------|--------------|
| `scan` | Full resolver scan (slowest start) |
| `cached` (default) | Start from cache without re-checking MTU |
| `verified` | Start from cache and re-check MTU |

The cache depends on resolvers, `domains` and the StormDNS version. `startup.max-age` is a duration string in whole days, from `0s` to `365d` (default `30d`; `720h` is also valid, the number `30` is not). Without a suitable cache, scanning runs again. System DNS changes invalidate the MTU cache and restart active dependent nodes without UI. Local DNS/SOCKS, resolver files, log paths and `startup.mode: ask` are forbidden in profiles.

</details>

<details>
<summary>Presets and fine tuning</summary>

Order: defaults → `preset` → explicit fields. Durations are strings with units (`600ms`, `30s`, `24h`, `30d`). Out-of-range values are rejected before startup.

| `preset` | Duplication (upload / download / upload-setup / download-setup) | Compression |
|----------|------------------------------------------------------------------|-------------|
| `messenger` (default) | 1 / 7 / 3 / 8 | `lz4` |
| `balanced` | 2 / 5 / 3 / 6 | `lz4` |
| `bulk` | 3 / 3 / 4 / 4 | `zstd` |

```yaml
proxies:
- name: storm
  type: stormdns
  domains:
  - v.example.com
  encryption: chacha20
  encryption-key: "<key>"
  preset: bulk
  duplication:
    upload: 2
  compression:
    upload: zlib
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - storm
```

| Block | Fields and bounds |
|-------|-------------------|
| `duplication` | `upload`, `download`, `upload-setup`, `download-setup` — 1…8 |
| `compression` | `upload`, `download` — `none`, `zstd`, `lz4`, `zlib`; `min-size` — 100…65535 |
| `mtu.upload`, `mtu.download` | `min` — 1…65535; `max` — 0…65535, where `0` removes the upper bound |
| `arq` | `window` 1…6000, `nack-max-gap` 0…1500, `max-control-retries` 5…5000, `max-data-retries` 60…100000; the rest are durations |
| `ping` | durations only: the `aggressive`/`lazy`/`cooldown`/`cold` intervals and the `warm`/`cool`/`cold` thresholds |
| `runtime` | `workers` and `process-workers` 1…64, queue and pool sizes, retry durations; `base-encode` is a flag |

Linked bounds are checked in full:

- `duplication.upload-setup` ≥ `upload`, `download-setup` ≥ `download`
- `mtu.<direction>.max` ≥ `min`
- `arq.initial-rto` ≤ `max-rto`, `arq.control-initial-rto` ≤ `control-max-rto`
- `arq.nack-max-gap` ≤ `arq.window / 4`
- `ping.aggressive-interval` ≤ `lazy-interval` ≤ `cooldown-interval` ≤ `cold-interval`
- `ping.warm-threshold` ≤ `cool-threshold` ≤ `cold-threshold`
- `runtime.process-workers` ≥ `runtime.workers`
- `runtime.session-retry-base` ≤ `session-retry-max`

Profile fields map to native keys through `core/backend/compile/storm_schema.json`, for example `arq.window` → `ARQ_WINDOW_SIZE`.

</details>

<a id="activation"></a>

## 😴 Sleeping reserve

OlcRTC and StormDNS default to `activation: auto`: they start on manual selection or failure of the watched group. A node must be a direct group member. With no selection or connections it sleeps after `sleep.idle`; `0s` prevents sleep until VPN restart. Use `activation: always` to start with the profile.

`activation` and `connectivity-check` belong inside a specific node in `proxies`. `activation: auto` requires a direct containing group and a wake URL (explicit or inherited from the node check, group or app settings); otherwise the profile is rejected. Durations in these two blocks must be whole seconds (`1s`, `1m`); `500ms` is invalid.

```yaml
proxies:
- name: rtc
  type: olcrtc
  provider: jitsi
  room: https://meet.example.org/room
  encryption-key: "<64-hex-key>"
  transport: datachannel
  dns-server: 1.1.1.1:53
  activation:
    mode: auto
    wake:
      urls:
      - https://example.org/generate_204
      interval: 30s
      failures: 2
      retry-after: 5m
    sleep:
      idle: 15m
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - rtc
```

<details>
<summary>Wake and sleep parameters</summary>

| Parameter | Default | Description |
|-----------|---------|-------------|
| `mode` | `auto` | `auto` puts the reserve to sleep; `always` — the legacy always-on startup |
| `wake.urls` | `connectivity-check` chain | Public HTTP(S) addresses to probe the watched group |
| `wake.interval` | `30s` | Probe interval while sleeping |
| `wake.failures` | `2` | Consecutive failed rounds before waking |
| `wake.retry-after` | `5m` | Pause after a failed start |
| `sleep.idle` | `15m` | Time without connections and selection before sleep; `0s` — never sleep until VPN restart |

</details>

<a id="checks"></a>

## 🩺 Connectivity checks

Process and SOCKS readiness are always checked. The HTTP(S) URL comes from node `connectivity-check.urls`, the nearest group or the app-wide test URL. `required: false` checks in the background; `true` requires a URL and rolls startup back on failure. Any valid HTTP response, including 4xx/5xx, counts as success.

```yaml
proxies:
- name: naive
  type: naiveproxy
  server: example.com
  port: 443
  username: user
  password: pass
  connectivity-check:
    urls:
    - https://example.org/generate_204
    required: true
```

Only public HTTP(S) URLs without credentials/fragment are allowed. DNS is checked before the request; traffic goes through the tested node’s SOCKS, with no direct fallback. TLS verifies the original hostname.

<details>
<summary>All check parameters</summary>

| Field | Default | What it sets |
|-------|---------|--------------|
| `urls` | — | At most 16 addresses to check (public HTTP(S), no credentials or fragments) |
| `required` | `false` | Whether the check is mandatory for startup |
| `timeout` | `5s` | Per-request timeout |
| `startup-timeout` | `30s` (`2m` for `stormdns`) | Overall check budget at startup |
| `retry-interval` | `1s` | Pause between attempts |
| `requests` | `1` | How many requests to make |
| `concurrency` | `1` | How many requests in parallel |
| `min-success-ratio` | — | Minimum fraction of successful responses (without it, one is enough) |

</details>

<a id="apps"></a>

## 🎯 Which apps use the VPN

Profile rules take priority over manual settings. `include-package` sends only listed apps through VPN; `exclude-package` sends all other apps. Choose one mode. An empty source `include-package: []` or `exclude-package: []` without other sources creates no profile rule: general settings apply.

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

| Format | Example | What it means |
|--------|---------|---------------|
| 🎯 Exact name | `com.termux` | Exact package match |
| ✳️ Wildcard | `*.yandex.*` | All Yandex apps |
| 🔤 Regex | `re:^org\.mozilla\..+$` | All Mozilla apps |
| 🚫 Exclusion | `!ru.yandex.browser` | Remove from the list |

`include-package-url` / `exclude-package-url` accept HTTP(S) lists: one package or selector per line. The previous cache works offline; subscriptions and app lists may use private servers. Local `include-package-file` / `exclude-package-file` are ignored on Android and logged.

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

While the VPN runs, the UI shows rules from the last successful tunnel creation. Reloading mihomo alone does not change them. If the snapshot is unavailable, the UI explicitly shows the profile declaration instead of confirmed state.

<a id="headers"></a>

## 🎨 Subscription headers

The subscription HTTP response carries YAML in its body and hints in headers. Both `flclashm-*` and compatible `flclashx-*` are accepted; the first takes priority. Boolean values are `true`/`false`.

```text
flclashm-custom: update
flclashm-hex: 5c6bc0:vibrant:pureblack
flclashm-view: type:tab;sort:delay;card:min
flclashm-settings: autostart,autoupdate
```

`flclashm-custom: add` applies `hex`, `view`, `widgets` and `settings` on import, `update` on every refresh; other headers do not depend on it. `flclashm-settings` applies when `overrideProviderSettings` is off: listed flags are enabled, absent flags reset to `false`. `androidsecure` only disables mixed-port, preserving the VPN choice. `GLOBAL` supports `flclashm-override` / `flclashx-override`, with the first taking priority.

<details>
<summary>Header and format reference</summary>

| Header | Value | Purpose |
|---|---|---|
| `flclashm-newdomain` / `flclashx-newdomain` | hostname | Saves a new host for the subscription URL; scheme, port and path stay unchanged |
| `flclashm-background` | `URL[,opacity]` | Background; optional image visibility 1–100 |
| `flclashm-hex` | `HEX[:variant][:pureblack]` | Color theme |
| `flclashm-widgets` | `list` | Widget order |
| `flclashm-view` | `key:value;…` | Node page layout |
| `flclashm-newboard` | `true/false` | New dashboard |
| `flclashm-denywidgets` | `true/false` | Disable dashboard editing |
| `flclashm-servicename` | `base64` | Service name |
| `flclashm-servicelogo` | `base64(URL)` | Service logo |
| `flclashm-serverinfo` | `base64` | Server-info group name |
| `flclashm-buyplan` | `URL` | Renew subscription |
| `flclashm-buytraffic` | `URL` | Buy traffic |
| `flclashm-settings` | `autostart,autoupdate,…` | Comma-separated settings |
| `flclashm-globalmode` | `false` | Hide global mode selection |
| `flclashm-androidsecure` | `true` | Disable mixed-port on Android |
| `flclashm-custom` | `add/update` | When to apply appearance |
| `announce` | `text/base64:…` | Announcement |
| `support-url` | `URL` | Support |
| `profile-update-interval` | integer hours | Subscription refresh interval; positive value |
| `x-hwid-max-devices-reached` | `true` | Device limit reached |
| `x-hwid-not-supported` | `true` | HWID unsupported |

`flclashm-hex`: a 6/8-digit hexadecimal color with optional `#`, then a Material 3 variant and `pureblack`. Variants: `tonalSpot`, `fidelity`, `monochrome`, `neutral`, `vibrant`, `expressive`, `content`, `rainbow`, `fruitSalad`.

`flclashm-view` pairs are separated by `;`; all keys are optional:

| Key | Allowed values |
|-----|----------------|
| `type` | `list`, `tab` |
| `sort` | `none`, `delay`, `name` |
| `layout` | `loose`, `standard`, `tight` |
| `icon` | `icon` (or `standard`), `none` |
| `card` | `expand`, `shrink`, `min`, `oneline` |

`flclashm-settings` flags:

| Flag | What it enables |
|------|-----------------|
| `autostart` | Auto-connect when the app opens (`ui.attach`) |
| `autoupdate` | Automatic update checking |
| `autorun` | Launch the app on system start *(desktop)* |
| `shadowstart` | Silent (background) launch |
| `minimize` | Minimize to tray on exit *(desktop)* |

</details>
