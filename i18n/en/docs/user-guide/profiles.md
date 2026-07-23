# 🧩 Built-in Nodes

FlClashM's superpower: **special nodes are described right in the YAML profile** and behave like ordinary proxies. The client launches the needed processes, hands them local ports, and plugs them into `mihomo`'s routing. In rules you can mix them freely — one site through `byedpi`, another through `olcrtc`, the rest directly.

Three types are supported:

| Type | What it does | When it helps |
|------|--------------|---------------|
| 🛡 [`byedpi`](#-byedpi) | DPI circumvention via packet manipulation | Resources blocked "from the inside": YouTube, Discord, etc. |
| 📞 [`olcrtc`](#-olcrtc) | A tunnel over WebRTC disguised as a video call | Bypassing whitelists (e.g. via Yandex Telemost / Jitsi) |
| 🎭 [`naiveproxy`](#-naiveproxy) | Parroting of Chrome traffic | Bypassing blocklists, resistance to TLS fingerprinting |

> ℹ️ Built-in nodes are defined **only** in the `proxies` section. Local addresses and ports are assigned by the client — you can't set them in the profile.

---

## 🔍 Startup check

Before considering a node ready, FlClashM always verifies two things: a **live process** and an **open local SOCKS port**. This applies to NaiveProxy, OlcRTC, and ByeDPI.

On top of that you can enable an **end-to-end check** — a real HTTP(S) request that goes strictly through the node's SOCKS port:

```yaml
connectivity-check:
  urls:
    - "https://example.org/generate_204"
  required: true
  timeout: 5
  startup-timeout: 30
  retry-interval: 1
  requests: 1
  concurrency: 1
  min-success-ratio: 1.0
```

| Field | Default | What it sets |
|-------|---------|--------------|
| `urls` | — | Addresses to check (public HTTP(S), no credentials or fragments) |
| `required` | `false` | Whether the check is mandatory for startup |
| `timeout` | `5` | Per-request timeout, seconds |
| `startup-timeout` | `30` | Overall check budget at startup, seconds |
| `retry-interval` | `1` | Pause between attempts, seconds |
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
```

How it works: candidates are checked in parallel in small groups. If nothing is found within the allotted budget, the node starts with a temporary (fallback) strategy while the rest of the list is checked in the background. The working strategy found is atomically switched into the plan and saved.

<details>
<summary>⚙️ All auto-mode parameters</summary>

| Parameter | Default | Description |
|-----------|---------|-------------|
| `strategy-list` | `byebyeedpi` | Strategy list name |
| `strategies` | — | Your own ordered argument list instead of `strategy-list` |
| `strategy-test.urls` | built-in YouTube endpoint | Addresses for selection |
| `strategy-test.sni` | — | Hostname to substitute for `{sni}` |
| `strategy-test.timeout` | `5` | Per-check timeout, seconds |
| `strategy-test.requests` | `1` | Requests per strategy |
| `strategy-test.concurrency` | `4` | Parallel HTTP requests inside a candidate |
| `strategy-test.min-success-ratio` | `1.0` | Minimum fraction of successful requests |
| `selection.concurrency` | `4` | Strategies checked at once |
| `selection.foreground-timeout` | `15` | Selection budget before the node starts, seconds |
| `selection.background` | `true` | Keep checking the list in the background after fallback |
| `fallback-args` | — | Temporary-strategy arguments if foreground didn't finish in time |
| `cache.ttl` | 7 days | Cache lifetime, seconds |
| `cache.recheck-after` | 1 day | Re-check interval, seconds |
| `cache.retry-after` | 5 minutes | Pause before a new selection after fallback, seconds |
| `cache.failure-threshold` | `2` | Errors before the cache is reset |

</details>

> ℹ️ `strategy-test` is used **only** during auto-selection and overrides the built-in test endpoint — it does not replace `connectivity-check`. The verified result and the temporary fallback are cached **separately**: fallback doesn't block later selection attempts for the normal TTL. Any HTTP check counts as success, including `4xx` and `5xx`.
>
> 🚫 The old `test` section is no longer supported — rename it to `strategy-test`.

### ✍️ Manual strategy

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

> 💡 If `mode` is omitted: the presence of `args` enables **manual** mode, and their absence enables **automatic** mode.

---

## 📞 OlcRTC

**Type:** `olcrtc` · UDP is not supported (only `udp: false` is allowed)

OlcRTC wraps traffic in WebRTC and passes it off as a regular video call through an allowed service — so the connection slips through whitelists.

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

| Parameter | Description |
|-----------|-------------|
| `auth.provider` | Connection provider: `jitsi`, `telemost`, `wbstream`, `none` |
| `room.id` | Video-call room identifier |
| `crypto.key` | 256-bit encryption key — **exactly 64 hex characters** |
| `net.transport` | Transport: `datachannel`, `vp8channel`, `seichannel`, `videochannel` |
| `net.dns` | Mandatory DNS server as `address:port` |

### 😴 Activation (sleeping reserve)

By default OlcRTC acts as a **fallback node**: the configuration is prepared in advance, but the process sleeps until the primary group starts failing or the user selects OlcRTC manually.

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
    interval: 30
    failures: 2
    retry-after: 300
  sleep:
    idle: 900
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `mode` | `auto` | `auto` puts the reserve to sleep; `always` — the legacy always-on startup |
| `wake.urls` | `connectivity-check` chain | Public HTTP(S) addresses to probe the watched group |
| `wake.interval` | `30` | Probe interval while sleeping, seconds |
| `wake.failures` | `2` | Consecutive failed rounds before waking |
| `wake.retry-after` | `300` | Pause after a failed start, seconds |
| `sleep.idle` | `900` | Time without connections and selection before sleep; `0` — never sleep until VPN restart |

**What matters about `auto`:**
- The node must directly belong to at least one proxy group.
- Check addresses must resolve from `wake.urls`, the node's `connectivity-check`, the nearest group, or the app's global test URL.
- After waking, the client immediately checks OlcRTC itself. If no containing group selected it and there are no active connections for `sleep.idle` — the process goes back to sleep.
- **Manual selection wakes the node immediately.**

> ℹ️ `auto` is now used **even without an `activation` field**. To fully restore the previous behavior, set `activation: always` explicitly.

> 💡 For `wbstream`, `vp8channel` is recommended: this provider's guest mode doesn't grant the right to publish a data channel. The optional `vp8.fps` and `vp8.batch_size` default to `30` and `64`.

If `profiles` are set, the top-level common fields are inherited by each fallback profile, and FlClashM validates the resulting configuration of each before startup. The local address, SOCKS5 port, CNC mode, and data directory are assigned by the client — they can't be overridden in the profile.

> ⚠️ Errors in required fields show up already during profile validation. If the OlcRTC process dies later, the client shows the **exit code and the last lines of output** instead of waiting for a port timeout.

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

## 🚧 Limitations

- Built-in nodes are defined only in the `proxies` section.
- The client manages local addresses and ports itself.
- The profile can't set a local `listen`; for NaiveProxy, `server` and `port` describe the remote server only.
- UDP: `byedpi` — enabled (can be disabled with `udp: false`); `naiveproxy` and `olcrtc` do **not** support UDP.

---

> 📎 Technical details of the node lifecycle — in [runtime](../development/runtime.md). Security guarantees — in the [security policy](../development/security.md).
>
> 🌍 Other languages: [Русский](../../../ru/docs/user-guide/profiles.md) · [中文](../../../zh/docs/user-guide/profiles.md) · [فارسی](../../../fa/docs/user-guide/profiles.md)
