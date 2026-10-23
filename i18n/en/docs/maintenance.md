# 🛠 Build and maintenance

[← README](../README.md) · [Русский](../../ru/docs/maintenance.md) · **English** · [中文](../../zh/docs/maintenance.md) · [فارسی](../../fa/docs/maintenance.md)

Repository commands and contracts to preserve when making changes. Branch, commit and PR rules are in [AGENTS.md](../../../AGENTS.md).

[Build](#build) · [Architecture](#architecture) · [Data](#data) · [Security](#security) · [Diagnostics](#diagnostics) · [Upstream](#upstream) · [Release](#release)

<a id="build"></a>

## 🏗 Build and checks

The NixOS environment is declared in `flake.nix`: Flutter 3.47.x, Go 1.27.2, JDK 17, SDK 37.0 and NDK 28.0.13004108/28.2.13676358. Change environment configuration declaratively.

```bash
nix develop -c make dev
nix develop -c make check
nix develop -c make go-check
```

`make check` covers product/base boundaries, GitHub Actions, release continuity, `test/product`/`test/tool` and targeted analysis. `make go-check` prepares vendor and runs gofmt, vet, host tests and the race detector across `core`; a C compiler is required. APK: `build/app/outputs/flutter-apk/app-debug.apk`.

<details>
<summary>Without Nix and separate test installation</summary>

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --debug --target-platform android-arm64
```

For an independent diagnostic installation, add `ORG_GRADLE_PROJECT_backendDiagnostic=true` to `flutter build apk --debug --target-platform android-arm64`. Package: `com.makriq.flclash.backendcheck`; CI `backend_test` uses `.backendtest`. Update while preserving data: `adb install -r -t`.

</details>

CI covers Go host/race, Dart/Flutter, Kotlin unit tests, ARM64/armeabi-v7a builds and x86_64 E2E with real mihomo, validator, ByeDPI and TUN. Documentation skips heavy jobs. An emulator does not replace ARM hardware: before release, check modes, nodes, subscriptions, UI/`:remote` death, preservation of Stop during recovery, network handover and battery use. Open findings are tracked in [#132](https://github.com/makriq-org/FlClashM/issues/132).

<a id="architecture"></a>

## 🧭 Architecture

```text
RawProfile + Settings + Capabilities
  → Go Compiler + SecurityPolicy
  → immutable RuntimePlan
  → RuntimeCoordinator
  → mihomo / external processes / Android VPN
```

Flutter owns presentation and drafts, submits commands and reads snapshots. `core/backend/**` owns profiles, settings, subscriptions, compilation and recovery; the portable package is tested without Android. `core/backend_host.go` connects mihomo and separate transport processes. Android provides permissions, foreground service, VPN/TUN, DNS and OS events.

RuntimeCoordinator is the sole owner of mutable runtime state. The backend lives in `:remote` independently of Flutter; `:validator` isolates the mihomo parser. `ui.attach` may prepare ordinary nodes without VPN. Stop is persisted before effects, cancels preparation and turns VPN off; ready nodes may remain for latency checks while UI is open. Headless preservation of Stop during recovery does not launch them; reset and Close stop everything.

Base code reaches `lib/product/**` through `tool/product_touchpoints.json`; widgets are registered in `allowedProductUi`. `lib/views/**` stays in base with minimal hooks. Other base changes require reasons in `tool/base_drift_allowlist.json`. Do not restore coordination or legacy SharedPreferences as state authority in Dart/Kotlin.

<details>
<summary>Backend contracts when changing runtime</summary>

**Desired** is persisted intent; **Applied** is the last confirmed plan; **Observed** is actual observation, unknown on error. Immutable RuntimePlan is checked by version and SHA-256. Preparation is separate from the effects queue; context and generation fence late results. Failure restores the confirmed plan or stops resources. VPN revoke persists Stop and requires a new explicit Start.

API, data and plan have independent versions, currently `1`. Request: `apiVersion`, `operationId`, `method`, `params`; response: `result` or `error`. Repeating an ID with the same content returns its prior result; different content is rejected. Wait for both the domain operation and its linked `runtimeOperationId`. Timeout or UI death does not cancel work; cancellation is explicit.

Main methods: `snapshot`, `runtime.view`, `presentation`, `runtime.*`, `operation.get/cancel`, `settings.patch`, `profile.*`, `subscription.refresh`, `proxy.select`, `backup.export/restore`, `blob.*`, `engine.command`, `ui.attach`, `data.reset`. Events carry `instanceId`/sequence; overflow requires resync. UI subscribes before the snapshot and shows applied selection from `runtime.view`. Slow subscribers do not block VPN.

</details>

<a id="data"></a>

## 💾 Data integrity

`backend-v1.json` stores intent, generation, confirmed input/plan and the operation journal using atomic rename and fsync. Recovery uses the last confirmed input; unfinished operations become interrupted. Revisions fence late subscription/editor writes. One-time migration preserves IDs, dates, original bytes, unknown fields and large integers.

ZIP preserves `config.json`, original profiles and provider cache. A missing source is not replaced with an empty file. Path traversal, symlinks and zip bombs are rejected. Binder transfers: 192 KiB chunks, up to 128 MiB per file, 32 unfinished transfers and 512 MiB total. Deleting the last profile persists Stop; reset stops work and preserves the migration marker and monotonic generations.

<a id="security"></a>

## 🔒 Security boundaries

Profiles cannot choose executable/home/ABI/certificates or local listeners. Arguments bypass the shell, SOCKS listens on loopback, and Linux/Android terminate children when the host dies. Normal, dev and test packages bypass VPN and use separate port ranges. Go SecurityPolicy runs before validation and sealing. The user’s VPN choice is preserved; `androidsecure` only disables mixed-port.

JS runs in Goja without host bindings, with deadline/cancel. Public-list and probe restrictions are in [profile setup](profiles.md#checks); private subscription and app-list servers are allowed. The HTTP controller checks its secret before commands; arbitrary config paths, upgrades and legacy runtime setters are blocked. DocumentsProvider does not expose internal journals or executable artifacts.

<a id="diagnostics"></a>

## 🩺 Diagnostics

There is no telemetry. Export on the logs screen creates a ZIP of Dart, Android, mihomo and node logs with `manifest.json` (versions, Android API/ABI, time and minimal state). Profiles, subscriptions, configs and IPC payloads are excluded. Secrets, credentials, subscription URLs and profile names are removed before writing and again at export.

Queues and rotation bound writes; slow logs do not block node shutdown. Android caps lines at 16 KiB, Go at 4 KiB with a 16-line queue. Mihomo logs without a Flutter listener. Export works even if `:remote` is unavailable; ZIP has `schemaVersion`, and redaction uses shared Dart/Kotlin test vectors.

<a id="upstream"></a>

## 🔄 Updating upstream and nodes

Create a branch from the target fork branch, run the commands below and resolve conflicts. The Dart package stays `flclashx`. Check base drift immediately after merging; register new paths with reasons. Without upstream, pass `--merge-base=<sha>` or `BASE_DRIFT_MERGE_BASE`. Runtime changes first ship as `-preN` with real Android verification.

```bash
git fetch upstream
git fetch origin
git merge upstream/dev
nix develop -c make drift check go-check
```

`tool/prepare_core.sh` recreates `core/vendor`, applies patches without fuzz and checks the Mieru regression. Builds use `-mod=vendor` without changing the shared module cache. Patches cover closed Mieru QUIC timeouts, the backend HTTP command gate and system DNS locking. Recheck each patch on update; remove upstream-fixed patches and their invocations while retaining vendor for remaining patches.

Node versions, ABIs and SHA-256 are in `lib/product/runtime/*_release.dart`, dependencies in [tool/runtime_go_modules](../../../tool/runtime_go_modules/README.md), sources beside [assets](../../../assets/runtimes/). Updates and rollbacks change source pins, dependencies and binaries together; then rebuild and verify released ABIs.

<a id="release"></a>

## 📦 Release and rollback

Version in `pubspec.yaml`: `MAJOR.MINOR.PATCH[-preN]+YYYYMMDDnn`. Breaking changes require MAJOR, features MINOR, fixes PATCH; include upstream’s user-visible effects. Every tag’s `versionCode` must increase. Tag `v<versionName>` only on a commit merged into main; release `applicationId`: `com.makriq.flclash`.

Create `release/<version>`, move user-facing Unreleased items to a CHANGELOG section matching the future tag exactly, update the version and run checks. After PR/merge, tag and push. CI verifies APK/AAB signatures and publishes universal/ABI APKs, AAB, SHA-256 and `FlClashM-android-release-metadata.json`. Prereleases appear in the app only when enabled in settings.

SourceForge is primary, GitHub is fallback. The stable/pre pointers below are verified against `.sig` with Ed25519 before JSON parsing. Each APK is checked by SHA-256, then Android verifies the package signature. Provider headers do not affect update trust.

```text
https://flclashm.sourceforge.io/update/stable.json
https://flclashm.sourceforge.io/update/pre.json
```

<details>
<summary>Publishing and downgrade protection</summary>

Publish `releases/<tag>` files first, then the pointer signature, then JSON last. Required secrets: `APP_UPDATE_SIGNING_KEY`, `SOURCEFORGE_SSH_KEY`, `SOURCEFORGE_USERNAME`. Extract APK codes using Android SDK: Flutter adds ABI offsets with `--split-per-abi`. The manifest code is the highest actual APK code; GitHub uses the same metadata codes.

Highest versionCode and publication time are stored per channel. Older signed manifests are rejected, and Android blocks APK downgrades. Roll back with a new corrective release carrying a higher code. Key rotation first requires a transitional app release containing the new public key.

</details>
