# 🧩 Built-in Nodes

FlClashM's superpower: **special nodes are described right in the YAML profile** and behave like ordinary proxies. The client launches the needed processes, hands them local ports, and plugs them into `mihomo`'s routing. In rules you can mix them freely — one site through `byedpi`, another through `olcrtc`, the rest directly.

Four types are supported:

| Type | What it does | When it helps |
|------|--------------|---------------|
| 🛡 [`byedpi`](#-byedpi) | DPI circumvention via packet manipulation | Resources blocked "from the inside": YouTube, Discord, etc. |
| 📞 [`olcrtc`](#-olcrtc) | A tunnel over WebRTC disguised as a video call | Bypassing whitelists (e.g. via Yandex Telemost / Jitsi) |
| 🌩 [`stormdns`](#-stormdns) | A tunnel inside DNS queries | Bypassing whitelists where only DNS is let through |
| 🎭 [`naiveproxy`](#-naiveproxy) | Parroting of Chrome traffic | Bypassing blocklists, resistance to TLS fingerprinting |

> ℹ️ Built-in nodes are defined **only** in the `proxies` section. Local addresses and ports are assigned by the client — you can't set them in the profile.

---

## 🔍 Startup check

Before considering a node ready, FlClashM always verifies two things: a **live process** and an **open local SOCKS port**. This applies to NaiveProxy, OlcRTC, ByeDPI, and StormDNS.

On top of that you can enable an **end-to-end check** — a real HTTP(S) request that goes strictly through the node's SOCKS port:

```yaml
connectivity-check:
  urls:
    - "https://example.org/generate_204"
  required: true
  timeout: 5s
  startup-timeout: 30s
  retry-interval: 1s
  requests: 1
  concurrency: 1
  min-success-ratio: 1.0
```

| Field | Default | What it sets |
|-------|---------|--------------|
| `urls` | — | Addresses to check (public HTTP(S), no credentials or fragments) |
| `required` | `false` | Whether the check is mandatory for startup |
| `timeout` | `5s` | Per-request timeout |
| `startup-timeout` | `30s` (`2m` for `stormdns`) | Overall check budget at startup |
| `retry-interval` | `1s` | Pause between attempts |
| `requests` | `1` | How many requests to make |
| `concurrency` | `1` | How many requests in parallel |
| `min-success-ratio` | — | Minimum fraction of successful responses (without it, one is enough) |

**How the address is chosen.** In order: the node's own `connectivity-check.urls` → the address of the nearest containing group → the app's global check address. If there's no address, only the process and port checks remain.

> ⚠️ **The difference between `required: false` and `required: true`:**
> - `false` — the check runs in the background, doesn't delay startup, and on failure only writes to the log.
> - `true` — a missing address **rejects** the profile, and a failed check **cancels** startup with a rollback of the prepared plan.
>
> **Any** valid HTTP response counts as success, including `4xx` and `5xx`. Only public HTTP(S) addresses without credentials or fragments are allowed.

---

## 🛡 ByeDPI

**Type:** `byedpi` · UDP is enabled by default (disable with `udp: false`)

ByeDPI defeats DPI by "corrupting" packets so the filter can't recognize the connection. The node has two modes.

### 🤖 Automatic strategy selection

The client cycles through strategies from the ByeByeDPI list, finds a working one, and caches it — on a cold start it's picked up immediately.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    strategies:
      - builtin:byebyeedpi
      - "--disorder 1"
      - "https://example.org/byedpi-strategies.txt"
```

How it works: candidates are checked in parallel in small groups. If nothing is found within the allotted budget, the node starts with a temporary (fallback) strategy while the rest of the list is checked in the background. The working strategy found is atomically switched into the plan and saved.

<details>
<summary>⚙️ All auto-mode parameters</summary>

| Parameter | Default | Description |
|-----------|---------|-------------|
| `strategies` | `[builtin:byebyeedpi]` | Built-ins, inline strategies, and public HTTPS lists in one order |
| `strategy-test.urls` | built-in YouTube endpoint | Addresses for selection |
| `strategy-test.sni` | — | Hostname to substitute for `{sni}` |
| `strategy-test.dns-resolver` | `https://1.1.1.1/dns-query` | DoH resolver for the test address (bypasses fake-ip); `system` uses the platform resolver |
| `strategy-test.timeout` | `5s` | Per-check timeout |
| `strategy-test.requests` | `1` | Requests per strategy |
| `strategy-test.request-concurrency` | `4` | Parallel HTTP requests inside a candidate |
| `strategy-test.min-success-ratio` | `1.0` | Minimum fraction of successful requests |
| `strategy-selection.strategy-concurrency` | `4` | Strategies checked at once |
| `strategy-selection.startup-timeout` | `15s` | Selection budget before the node starts |
| `strategy-selection.continue-in-background` | `true` | Keep checking the list in the background after fallback |
| `strategy-selection.fallback-strategy` | — | Temporary-strategy arguments if foreground didn't finish in time |
| `strategy-selection.cache.ttl` | `7d` | Cache lifetime |
| `strategy-selection.cache.recheck-after` | `1d` | Re-check interval |
| `strategy-selection.retry-after` | `5m` | Pause before a new selection after fallback |
| `strategy-selection.cache.failure-threshold` | `2` | Errors before the cache is reset |

</details>

An HTTPS file contains one strategy per line; blank lines and lines beginning
with `#` are ignored. Links use the same public-HTTPS, size, timeout, and stale
cache limits as StormDNS lists.

> ℹ️ `strategy-test` is used **only** during auto-selection and overrides the built-in test endpoint — it does not replace `connectivity-check`. The verified result and the temporary fallback are cached **separately**: fallback doesn't block later selection attempts for the normal TTL. Any HTTP check counts as success, including `4xx` and `5xx`.
>
> 🚫 The old `test` section is no longer supported — rename it to `strategy-test`.

### ✍️ Manual strategy

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    strategy: "--disorder 1 --auto=torst --tlsrec 1+s"
```

> 💡 New profiles set `mode` explicitly; omitting it selects automatic mode.

---

## 📞 OlcRTC

**Type:** `olcrtc` · UDP is not supported (only `udp: false` is allowed)

OlcRTC wraps traffic in WebRTC and passes it off as a regular video call through an allowed service — so the connection slips through whitelists.

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    provider: jitsi
    room: "https://meet.example.org/room"
    encryption-key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    transport: datachannel
    dns-server: "1.1.1.1:53"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

| Parameter | Description |
|-----------|-------------|
| `provider` | Connection provider: `jitsi`, `telemost`, `wbstream`, `none` |
| `room` | Video-call room identifier |
| `encryption-key` | 256-bit encryption key — **exactly 64 hex characters** |
| `transport` | Transport: `datachannel`, `vp8channel`, `seichannel`, `videochannel` |
| `dns-server` | Mandatory DNS server as `address:port` |
| `transport-options` | Options of the selected transport; forbidden for `datachannel` |

Options depend on the transport: `vp8channel` accepts `fps` and `batch-size`;
`seichannel` also accepts `fragment-size` and a duration-string `ack-timeout`;
`videochannel` accepts `codec`, `width`, `height`, `fps`, `bitrate`,
`fragment-size`, `qr-recovery`, `tile-module`, and `tile-rs`.

```yaml
transport: seichannel
transport-options:
  fps: 30
  batch-size: 64
  fragment-size: 900
  ack-timeout: 2s
```

> 💡 For `wbstream`, `vp8channel` is recommended: this provider's guest mode doesn't grant the right to publish a data channel. `transport-options.fps` and `transport-options.batch-size` are required.

`profiles`, `failover`, and `video.hw` are removed from the public contract. Define separate OlcRTC nodes and combine them with a Mihomo group. `provider: none` requires `engine`, `engine-url`, and `engine-token`; other providers forbid them.

> ⚠️ Errors in required fields show up already during profile validation. If the OlcRTC process dies later, the client shows the **exit code and the last lines of output** instead of waiting for a port timeout.

---

## 🌩 StormDNS

**Type:** `stormdns` · UDP is not supported (only `udp: false` is valid)

StormDNS wraps TCP into ordinary DNS queries to an allowed resolver — so the connection slips through whitelists. The goal is the same as OlcRTC's, but the carrier differs — DNS: the node targets networks that let only DNS queries through. It is **noticeably slower** than the others.

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

### 🔑 Required fields

`domains`, `encryption`, and `encryption-key` are **required and have no defaults**: StormDNS negotiates nothing, so all three must match the server exactly.

| Field | Description |
|-------|-------------|
| `domains` | Domains delegated to the StormDNS server |
| `encryption` | `none`, `xor`, `chacha20`, `aes-128-gcm`, `aes-192-gcm`, `aes-256-gcm` |
| `encryption-key` | Shared key; must match the server |

> ⚠️ The `none` and `xor` modes **do not protect the payload** from the resolver operator, who can read your traffic. Use them only when the server requires it.

### 📍 Resolvers

`resolvers` is one list of sources, processed in order:

| Entry | What it adds |
|-------|--------------|
| `system` | DNS servers of the physical (non-VPN) network |
| `8.8.8.8` | One resolver on port 53 |
| `1.1.1.1:5353` | One resolver on its own port |
| `192.168.1.0/30` | CIDR: for IPv4 the network and broadcast addresses are skipped; a range wider than 65536 addresses is rejected |
| `https://…` | Resolvers from a remote list |

When `resolvers` is absent or empty, `[system]` is used. After every source is expanded, duplicates are dropped by IP: the first occurrence and its port win. If the final list is empty, the profile is not applied.

List addresses must be HTTPS, without credentials or a fragment; localhost and local addresses are refused — but private IPs and CIDRs **inside** a list are fine. A profile may reference at most 32 distinct list addresses. Responses are capped at 1 MiB with a 15-second timeout. Each address is cached separately: an unreachable list falls back to its last stored copy even past `refresh`, and a list with no stored copy is skipped so the remaining sources still work.

| `resolver-policy` | Default | Description |
|-------------------|---------|-------------|
| `refresh` | `24h` | How often remote lists are refreshed |
| `strategy` | `least-loss` | `random`, `round-robin`, `least-loss`, `lowest-latency` |
| `auto-disable` | `true` | Disable resolvers that stop answering |
| `recheck` | `true` | Periodically re-test disabled resolvers |

`refresh` is checked when the profile is applied — there is no standing timer.

### 🎚 Presets

`preset` sets packet duplication and compression. Layering order: **StormDNS defaults → preset → explicitly set fields**.

| `preset` | Duplication (upload / download / upload-setup / download-setup) | Compression |
|----------|------------------------------------------------------------------|-------------|
| `messenger` (default) | 1 / 7 / 3 / 8 | `lz4` |
| `balanced` | 2 / 5 / 3 / 6 | `lz4` |
| `bulk` | 3 / 3 / 4 / 4 | `zstd` |

Any field can be overridden on its own; no separate construct is needed:

```yaml
preset: bulk
duplication:
  upload: 2
compression:
  upload: zlib
```

Fine tuning lives in the `duplication`, `compression`, `mtu`, `arq`, `ping`, and `runtime` blocks. Every duration, including shared `activation` and `connectivity-check` fields, is a string with a unit (`600ms`, `30s`, `24h`, `30d`).

> ℹ️ StormDNS silently clamps out-of-range values. FlClashM **reports an error before startup** instead.

<details>
<summary>📐 Fine-tuning bounds</summary>

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

Field names match the StormDNS config.

</details>

### 🚀 Startup

| `startup.mode` | What it does |
|----------------|--------------|
| `scan` | Full resolver scan (slowest start) |
| `cached` (default) | Start from cache without re-checking MTU |
| `verified` | Start from cache and re-check MTU |

`startup.max-age` (default `30d`) limits how old a usable cache may be and must resolve to a whole number of days.

> ⏳ The first startup goes through a resolver scan and can take up to two minutes — that is what the check budget allows for.

The working cache is bound to the final resolver list, `domains`, and the StormDNS build. Changing profile sources, `domains`, or the build creates a new cache, and the old one is only removed once the profile applies successfully. A physical-network DNS change clears the current cache before restarting the node. If no suitable cache exists, or StormDNS rejects it, it falls back to a full scan on its own — that is expected.

The log directory, resolver file, local port, and SOCKS5 listener are owned by the app and cannot be set in the profile.

### 📶 System DNS

When `resolvers` contains `system` (or is absent), the node depends on the DNS of the physical network. When those change, the platform rewrites the resolver file, resets the working cache, and restarts **only** the active dependent nodes — including at cold start with no UI running. No separate bypass is needed: the app package is already excluded from VPN routing.

---

## 🎭 NaiveProxy

**Type:** `naiveproxy` · UDP is not supported (only `udp: false` is allowed)

NaiveProxy disguises traffic as ordinary Chrome requests using Chromium's network stack — this is resistant to TLS fingerprinting and active probing.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

- **Required fields:** `name`, `type`, `server`, `port`, `username`, `password`.
- `transport` defaults to `https`; `quic` is also allowed.
- Optional: `insecure-concurrency` (1–4), `tunnel-timeout`, `idle-timeout`, `post-quantum`, a `headers` map, `host-resolver-rules`, and a shared `connectivity-check`.

The client safely builds a URI with escaped credentials, passes it to NaiveProxy, and replaces the node for `mihomo` with a local SOCKS5.

> 🚫 The old `proxy` field is not supported. `listen`, diagnostic files, proxy chains, and any unknown fields are **rejected** during profile validation.

---

## 😴 Activation: the sleeping reserve (OlcRTC and StormDNS)

By default OlcRTC and StormDNS act as **fallback nodes**: the configuration is prepared in advance, but the process sleeps until the primary group starts failing or the user selects the node manually.

```yaml
activation: auto
# activation: always  # legacy mode: start together with the VPN
```

The full form gives control over waking and sleeping:

```yaml
activation:
  mode: auto
  wake:
    urls: ["https://example.org/generate_204"]
    interval: 30s
    failures: 2
    retry-after: 5m
  sleep:
    idle: 15m
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `mode` | `auto` | `auto` puts the reserve to sleep; `always` — the legacy always-on startup |
| `wake.urls` | `connectivity-check` chain | Public HTTP(S) addresses to probe the watched group |
| `wake.interval` | `30s` | Probe interval while sleeping |
| `wake.failures` | `2` | Consecutive failed rounds before waking |
| `wake.retry-after` | `5m` | Pause after a failed start |
| `sleep.idle` | `15m` | Time without connections and selection before sleep; `0s` — never sleep until VPN restart |

**What matters about `auto`:**
- The node must directly belong to at least one proxy group.
- Check addresses must resolve from `wake.urls`, the node's `connectivity-check`, the nearest group, or the app's global test URL.
- After waking, the client immediately checks the node itself. If no containing group selected it and there are no active connections for `sleep.idle` — the process goes back to sleep.
- **Manual selection wakes the node immediately.**

> ℹ️ `auto` is now used **even without an `activation` field**. To fully restore the previous behavior, set `activation: always` explicitly.

---

## 🚧 Limitations

- Built-in nodes are defined only in the `proxies` section.
- The client manages local addresses and ports itself.
- The profile can't set a local `listen`; for NaiveProxy, `server` and `port` describe the remote server only.
- UDP: `byedpi` — enabled (can be disabled with `udp: false`); `naiveproxy`, `olcrtc`, and `stormdns` do **not** support UDP.

---

> 📎 Technical details of the node lifecycle — in [runtime](../development/runtime.md). Security guarantees — in the [security policy](../development/security.md).
>
> 🌍 Other languages: [Русский](../../../ru/docs/user-guide/profiles.md) · [中文](../../../zh/docs/user-guide/profiles.md) · [فارسی](../../../fa/docs/user-guide/profiles.md)
