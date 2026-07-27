# ⚙️ Runtime

## 🔗 Processing pipeline

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan
```

After that, `EngineManager` and `EngineAdapter` manage the lifecycle.

---

## 🔍 Built-in node verification

Starting NaiveProxy, OlcRTC, ByeDPI, and StormDNS goes through **two stages**:

1. ✅ confirming a live process and a local SOCKS port;
2. 🌐 an end-to-end HTTP(S) request strictly through that SOCKS port.

The product layer validates and serializes the contract from `lib/product/runtime/connectivity_check.dart`, and the Android service executes it via `RuntimeNodeConnectivityChecker`.

**Transactionality.** The required check is part of the startup transaction: exhausting `startup-timeout` stops new nodes and triggers a rollback of the prepared plan. The optional check runs in the background and only affects the log. The stored manifest carries the same contract, and the Android platform layer runs it before the fast core start during always-on recovery — so **normal and cold starts have identical success conditions**.

**No direct fallback connection.** The name is resolved before the SOCKS request, all resolved addresses must be public, and the SOCKS command gets the already-verified IP. TLS validates the certificate for the original name.

**Process ownership.** The Android service is the sole owner of both the working processes and the temporary ByeDPI strategy-selection processes. A single `probeRuntimeNode` is serialized with the working-plan swap; the batch call holds the lock only while checking the snapshot and doesn't block a plan swap during network requests. Both paths require the mandatory safe check, always terminate the temporary process, and never change the live or stored plan. A failed candidate is discarded; rollback uses the previous cache, or the built-in fallback strategy if there's none. Updating this path is done together for the Dart bridge, AIDL, and the Android service; reverting to a previous version needs no cache-data migration.

**Auto-selection (batch).** The Android service launches a limited number of candidates on different loopback ports, returns the first successful one, and cancels the rest. One candidate performs a single series of HTTP(S) requests without retries and without doubling the timeout. Dart limits the foreground stage with a monotonic overall budget; after it, it starts the fallback and continues the list in the background. A successful background result is atomically promoted to the verified cache, re-applies the full runtime plan, and updates the cold-start manifest. A plan swap cancels the continuation via a generation token, and Android always finishes an already-started batch.

---

## 🧩 Built-in nodes

Built-in nodes are declared as ordinary proxies in the profile. Their lifecycle is managed by `BuiltInProxySupervisor`.

> 📎 The user-facing side (YAML, parameters) is described in the [built-in nodes guide](../user-guide/profiles.md).

### 🎭 naiveproxy

- **Type:** `naiveproxy`
- **Required fields:** `name`, `type`, `server`, `port`, `username`, `password`
- Only `https` and `quic` transports are allowed; anonymous access is forbidden
- UDP is not supported; the resulting local `mihomo` node gets `udp: false`
- The client picks the local SOCKS5 address itself
- The compiler escapes credentials, builds a single internal URI, and starts NaiveProxy with an auto-generated `config.json`
- The allowlist rejects `proxy`, `listen`, diagnostic files, proxy chains, and unknown fields

### 📞 olcrtc

- **Type:** `olcrtc`
- **Required fields:** `name`, `auth.provider`, `room.id` (except `none`), `crypto.key`, `net.transport`, `net.dns`
- Works only in CNC (client) mode
- UDP is not supported; the resulting local `mihomo` node gets `udp: false`
- Before startup FlClashM validates the required fields, allowed providers and transports, the key, DNS, and each resulting fallback profile
- The Android service keeps a limited tail of the process output; if OlcRTC exits before opening the SOCKS5 port, the reason is returned to Dart immediately and shown to the user
- Runs as a separate process via the stable `config.yaml` contract; the mobile library is not used
- The sources are pinned to commit `ad5758513335cda54362a64621c29e9d9fe759b4`
- `data: data` is required for the CLI, but a separate directory layout isn't needed: the name dictionaries are embedded in the executable, and missing external files are treated as an optional override
- The SHA-256 of each binary is pinned next to the commit; asset preparation and tests reject outdated or altered files even with a matching stamp

<details>
<summary>🔧 Updating and rolling back olcrtc</summary>

- **Update:** change the pinned commit, rebuild the three Android ABIs with pinned Go 1.26.4 and NDK 28.0.13004108 via `dart setup.dart android --out runtime-assets`, update the pinned SHA-256 from the produced files, and rerun the command and tests.
- **Rollback:** restore the previous commit `5dd6822d807e3352fe4452a3b071e043d958a020` and rebuild the artifacts with the same command.

</details>

### 🌩 stormdns

- **Type:** `stormdns`
- **Required fields:** `name`, `type`, `domains`, `encryption`, `encryption-key`
- The required fields have no defaults: StormDNS performs no protocol negotiation, so the values must match the server
- UDP is not supported; the resulting local `mihomo` node gets `udp: false`
- The `messenger` / `balanced` / `bulk` presets set duplication and compression; the layering order is **StormDNS defaults → preset → explicit fields**
- Schema ranges are taken from StormDNS `finalizeClientConfig`: anything upstream would silently clamp is rejected before launch. Linked bounds are checked in full — `upload-setup` ≥ `upload`, `download-setup` ≥ `download`, `mtu.*.max` ≥ `min`, `nack-max-gap` ≤ `window/4`, `process-workers` ≥ `workers`, and the ordering of RTO values, ping intervals, ping thresholds and `session-retry-base` ≤ `session-retry-max`
- Declares startup-failure marker lines; the service stops waiting for the port as soon as one matches, instead of sitting out the 120 s budget
- Sources are pinned to commit `87348df5b11f9e490262a713ca268734007af44f`
- The SHA-256 of every binary is pinned next to the commit; asset preparation and tests reject stale or modified files even when the stamp matches

<details>
<summary>🔧 Updating and rolling back stormdns</summary>

- **Update:** change the pinned commit, rebuild the three Android ABIs with the pinned Go 1.26.4 and NDK 28.0.13004108 via `dart setup.dart android --out runtime-assets`, refresh the pinned SHA-256 values from the produced files, and re-run the command and the tests.
- **Rollback:** the node ships for the first time, so there is no previous pinned commit. A version rollback means restoring the commit and rebuilding the same way; the operational rollback for a user is removing the node from the profile. No data migration is needed: the working cache is keyed by fingerprint and is rebuilt.

</details>

**Resolver file.** The Android launch contract is extended **generically, with no node-type checks**: a node declares `resolverFile` with `template`, `path`, `dependsOnSystemDns`, and `resetPaths`. The profile stages only the template (`client_resolvers.template`), while the file the process reads (`client_resolvers.txt`) is generated by the platform — so a platform rewrite never looks like a profile change and does not restart nodes on every apply. When the system DNS changes, `RuntimeNodeResolverFile` regenerates the file atomically, resets the paths from `resetPaths`, and restarts **only the active dependent** nodes. `SystemDnsReader` reads the system DNS itself, because a cold start applies the plan before `NetworkObserveModule` is installed.

**Multi-artifact transactions.** `LocalNodeController` serves several files per node through stage → rollback → commit. The revision of single-file nodes stayed byte-for-byte identical, so NaiveProxy, OlcRTC, and ByeDPI behaviour is unchanged. The working cache is keyed by a fingerprint of the final resolver list, `domains`, and the StormDNS version; the old directory is removed only **after** a successful commit, and a rollback restores the previous plan's state.

**A deliberate deviation from upstream.** StormDNS `usableHostCount` returns 2 for an IPv4 `/1` and then iterates 2³¹−2 addresses. FlClashM computes the actual expansion size and checks it against the documented 65536 limit: a CIDR from the profile that doesn't fit is rejected before launch, while a list fetched over a link is truncated to the limit. Otherwise such a profile would hang the app.

### 🛡 byedpi

- **Type:** `byedpi`
- **`manual` mode:** takes an `args` string
- **`auto` mode:** cycles through ByeByeDPI strategies and caches the working one
- Without `mode`, the presence of `args` picks manual, and their absence picks automatic
- `strategy-list` in auto mode defaults to `byebyeedpi`; without `strategy-test.urls` the built-in YouTube test endpoint is used
- `{sni}` substitution is supported
- UDP is enabled by default and passed to the local `mihomo` node; `udp: false` disables it, and the ByeDPI process itself gets no separate UDP parameter

### 😴 `auto` activation (olcrtc and stormdns)

The supervisor stages a sleeping node's artifacts in advance but doesn't include it in the live or cold-start manifest, so its mandatory end-to-end check is no longer part of the VPN startup transaction. The watchdog probes the watched group, wakes the reserve after a set number of failures, atomically applies the full plan, and force-refreshes the node's own delay. After a period without connections and selection in all direct containing groups, the plan is applied without it and the process goes back to sleep. A profile change or stop cancels transitions via a generation token; sleep state isn't persisted and starts over after a reboot.

Access to `mihomo` and network state is isolated behind the `RuntimeHealthProbe` interface: the product layer sees only the delay test, the chains of active connections, the current group `now`, and network presence. The implementation lives in the app layer on top of `clashCore` and `connectivity_plus`. Without an injected probe the automatic watchdog is idle, but staging, stop, and manual wake remain safe. The `always` mode doesn't use this path and keeps the previous startup transaction.

The integration updates together with the app's Dart part and doesn't change the Android bridge; the live rollback is `activation: always`, and a version rollback needs no state migration.

---

## 🚧 Limitations

- Built-in nodes work only in the `proxies` section
- Local addresses and ports are determined by the client
- ByeDPI in `auto` mode checks URLs from `strategy-test.urls` or the built-in YouTube endpoint
- StormDNS is slow by design: a cold start includes an MTU scan of the resolvers (28 s for three resolvers on a real device), so its default `startup-timeout` is raised to 120 s

---

## 📸 Android VPN applied-options snapshot

**Place in the architecture.** `FlVpnService` stores an immutable snapshot of the options in `State.appliedOptions` **only after** a successful `VpnService.Builder.establish()` and exposes it through a separate AIDL/MethodChannel contract `getAppliedAndroidVpnOptions`. `AccessControlService` compares the snapshot with the current profile's declaration; the base screen only receives the finished state.

**Contract and constraints:**

- an empty response means no confirmed snapshot is available;
- JSON with `includePackage: []` or `excludePackage: []` keeps an explicit mode with an empty list and is not the same as a missing rule;
- the snapshot isn't updated on a plain core config reload, because Android package rules change only when the VPN is recreated;
- the channel is read-only and doesn't affect routing;
- when the snapshot is unavailable, the UI explicitly states that it's showing the **profile declaration** and doesn't present it as the applied state.

**Update and rollback.** Done by adding a new method without touching the old `getAndroidVpnOptions` needed to start the VPN. Rollback is safe: the old startup path stays unchanged, and the absence of the new response maps to a "verification unavailable" state.

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/runtime.md) · [中文](../../../zh/docs/development/runtime.md) · [فارسی](../../../fa/docs/development/runtime.md)
