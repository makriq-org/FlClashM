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

`make check` covers product/base, GitHub Actions, release continuity, `test/product`/`test/tool`, errors across all `lib` (`analyze-app`) and targeted analysis. `make go-check` prepares vendor, checks gofmt for `core/backend`, then runs vet, host tests and the race detector across `core` with `GOFLAGS=-mod=vendor`; a C compiler is required. APK: `build/app/outputs/flutter-apk/app-debug.apk`.

<details>
<summary>Without Nix and separate test installation</summary>

The native Rust editor requires NDK r28 or newer with `libclang`. `ANDROID_NDK` selects the NDK for Go builds, while Flutter native hooks use `ANDROID_NDK_HOME`: both must point to the selected NDK. Nix and the shared CI setup set them automatically. When building without Nix, run `export ANDROID_NDK_HOME="$ANDROID_NDK"` before the commands below.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --debug --target-platform android-arm64
```

For an independent diagnostic installation, add `ORG_GRADLE_PROJECT_backendDiagnostic=true` to `flutter build apk --debug --target-platform android-arm64`. Package: `com.makriq.flclash.backendcheck`; manual CI with `backend_test` uses `.backendtest`. Update while preserving data: `adb install -r -t`.

For a simplified local build of the test variant, run `ORG_GRADLE_PROJECT_backendTest=true flutter build apk --release --target-platform android-arm64` after preparing core and assets; package: `com.makriq.flclash.backendtest`. CI also passes `--dart-define=APP_ENV=pre` and `--dart-define=CORE_VERSION` with the value from `lib/core_version.dart`.

</details>

CI covers Go host/race, Dart/Flutter, Kotlin unit tests, ARM64/armeabi-v7a builds and x86_64 E2E with real mihomo, validator, ByeDPI and TUN. Documentation skips heavy jobs. UI/backend Dart bridge changes trigger E2E with the real Flutter activity; instrumentation errors and unhandled Flutter exceptions fail the check. An emulator does not replace ARM hardware: before release, check modes, nodes, subscriptions, UI/`:remote` death, preservation of Stop during recovery, network handover and battery use. Open findings are tracked in [#132](https://github.com/makriq-org/FlClashM/issues/132). The `secret-scan` workflow checks PR and push commits with Gitleaks.

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

RuntimeCoordinator is the sole owner of mutable runtime state. The backend lives in `:remote` independently of Flutter; `:validator` isolates the mihomo parser. `ui.attach` may prepare ordinary nodes in advance without VPN. Stop is persisted before effects, cancels preparation and turns VPN off; ready nodes may remain for latency checks while UI is open. Headless recovery after Stop does not launch them; reset and Close stop everything.

When the backend instance changes or the Binder connection recovers, a live UI repeats `ui.attach` with a new `operationId` and `restore: true`. Go restores UI presence and node preparation without repeating `autoRun`; the stopped intent after an explicit Stop is preserved. Without `restore`, the first opening uses the normal `autoRun` policy.

Base code reaches `lib/product/**` through `tool/product_touchpoints.json`; widgets are registered in `allowedProductUi`. Keep live screens in `lib/views/**` without duplicating them in product; they may evolve to fit the FlClashM architecture while complying with guards and the allowlist and registering links to product as touchpoints. Tracked base changes require reasons in `tool/base_drift_allowlist.json`; a touchpoint does not replace that entry. Do not restore coordination or legacy SharedPreferences as state authority in Dart/Kotlin.

<details>
<summary>Backend contracts when changing runtime</summary>

**Desired** is persisted intent; **Applied** is the last confirmed plan; **Observed** is actual observation, unknown when the state cannot be confirmed. Immutable RuntimePlan is checked by version and SHA-256. Preparation is separate from the effects queue; context and generation fence late results. Failure restores the confirmed plan or stops resources. VPN revoke persists Stop and requires a new explicit Start. The queue is limited to 8 accepted commands, with reserved capacity for Stop.

API, data and plan have independent versions, currently `1`. Request: `apiVersion`, `operationId`, `method`, `params`; response: `result` or `error`. Repeating an ID with the same content returns its prior result; different content is rejected. Wait for both the domain operation and its linked `runtimeOperationId`. Timeout or UI death does not cancel work; cancellation is explicit.

Main methods: `snapshot`, `runtime.view`, `presentation`, `runtime.*`, `operation.get/cancel`, `settings.patch`, `profile.*`, `subscription.refresh`, `proxy.select`, `backup.export/restore`, `blob.*`, `engine.command`, `ui.attach`, `data.reset`. Events carry `instanceId`/sequence; overflow requires resync. UI subscribes before the snapshot and shows applied selection from `runtime.view`. Slow subscribers do not block VPN.

</details>

<a id="data"></a>

## 💾 Data integrity

`backend-v1.json` stores runtime intent, generation, confirmed input/plan and runtime receipts; `application-v1.json` stores the domain operation ledger (up to 2 MiB); `profiles.json` stores the profile catalog and settings. All three files are written with atomic rename and fsync. Recovery uses the last confirmed input; unfinished operations become interrupted. Revisions fence late subscription/editor writes. One-time migration preserves IDs, dates, original bytes, unknown fields and large integers.

ZIP preserves `config.json`, original profiles and provider cache. A missing source is not replaced with an empty file. Path traversal, symlinks and zip bombs are rejected. Binder transfers: 192 KiB chunks, up to 128 MiB per file, 32 unfinished transfers and 512 MiB total. Deleting the last profile persists Stop; reset stops work and preserves the migration marker and monotonic generations.

Go refreshes subscriptions and app lists without UI and retains the previous cache on network failure. Subscription expiry notices use thresholds of 3/2/1/0 days and expired; Go persists deduplication, Android localizes display.

<a id="security"></a>

## 🔒 Security boundaries

The trusted host supplies executable paths, app directory, ABI, certificates and local ports. An occupied node port is rejected before launch. Arguments bypass the shell, SOCKS listens on loopback, and Linux/Android terminate children when the host dies. Normal, dev and test packages bypass VPN and use separate port ranges. Go SecurityPolicy runs before validation and plan sealing. The user’s VPN choice is preserved; `androidsecure` only disables mixed-port.

JS runs in Goja without host bindings, with deadline/cancel. Public-list and probe restrictions are in [profile setup](profiles.md#checks); private subscription and app-list servers are allowed. The HTTP controller checks its secret before commands; arbitrary config paths, upgrades and legacy runtime setters are blocked. DocumentsProvider does not expose internal journals or executable artifacts.

<a id="diagnostics"></a>

## 🩺 Diagnostics

There is no telemetry. Export on the logs screen creates a ZIP of Dart, Android, mihomo and node logs with `manifest.json` (versions, Android API/ABI, time and minimal state). Profiles, subscriptions, configs and IPC payloads are excluded. Secrets, credentials, subscription URLs and profile names are removed before writing and again at export.

Queues and rotation bound writes; slow logs do not block node shutdown. Android caps lines at 16 KiB, Go at 4 KiB with a 16-line queue. Mihomo logs without a Flutter listener. Export works even if `:remote` is unavailable; ZIP has `schemaVersion`, and redaction is verified with shared Dart/Kotlin test vectors.

<a id="upstream"></a>

## 🔄 Updating upstream and nodes

The architecture and reliability of the independent Go backend take priority over minimizing upstream differences. Port fixes and features selectively; choose a full merge after assessing its benefits, conflicts and runtime impact. Preserve the Flutter ↔ backend and base ↔ product boundaries.

Create a branch from the target fork branch. After fetching, explicitly choose an upstream ref (branch or tag), record its full SHA in the work/PR description, and port selected changes or perform a justified merge of that SHA. Our Dart package is `flclashx`; check the upstream package name (for example, `fl_clash`) and adapt imports and generation when needed.

Immediately check drift against the selected SHA with `dart tool/check_base_drift.dart --upstream-ref=<upstream-sha>`. Alternatively, supply an explicit common ancestor via `--merge-base=<sha>` or `BASE_DRIFT_MERGE_BASE`. Guards, touchpoints and the allowlist remain mandatory. The guard and CI default to `upstreamImport.commit` in `tool/base_drift_allowlist.json`. Exact imports are verified against that SHA, allowing only the Dart package rename. Other base changes require reasons in the allowlist; links to product also need touchpoint entries. Update the CI fetch when changing the pin. Runtime changes first ship as `-preN` with real Android verification.

```bash
git fetch upstream
git fetch origin
nix develop -c make check go-check
```

`tool/prepare_core.sh` recreates `core/vendor`, applies patches without fuzz and checks the Mieru regression. Builds use `-mod=vendor` without changing the shared module cache. Patches cover the backend HTTP command gate and synchronized system DNS access. The closed Mieru QUIC timeout fix is now upstream; its regression test is retained. Recheck each patch on update; remove upstream-fixed patches and their invocations while retaining vendor for remaining patches.

Node versions, source commits, ABIs and SHA-256 are pinned in `lib/product/runtime/*_release.dart`; dependencies are in [tool/runtime_go_modules](../../../tool/runtime_go_modules/README.md), build notes in [assets](../../../assets/runtimes/). Updates and rollbacks change pins, dependencies and binaries together; then rebuild and verify released ABIs.

<a id="olcrtc-audit"></a>

<details>
<summary>OlcRTC: source, builds and limitations</summary>

- Uses `ghostlane-project/olcrtc`, branch `proofkit`, v0.12.1, commit `b2c4b17ee35bfe65330aa9141f94dac082228bb2`; sources are built without local patches
- v0.12.1 fixes VK Calls RTP payload-type conflicts during connection and renegotiation; dependencies and the config format are preserved
- New providers: `vkcalls` with `vp8channel` or `videochannel`, `mtslink` with `vp8channel`, and `salutejazz` and `max` with `datachannel`. `max` requires `provider-token`; guest `vkcalls` rejects non-empty tokens. New engines are selected through providers: they need additional credentials absent from the direct `engine-url`/`engine-token` contract
- New Ghostlane UDP/direct/failover/DTLS settings are not exposed in FlClashM profiles: CNC, loopback SOCKS, sole Go ownership of runtime and existing Mihomo routing are preserved
- Dependencies remain in `tool/runtime_go_modules/olcrtc.mod/.sum` with FlClashM security updates; pinned `covert-dtls` was added. Its camouflage profile is not enabled
- When the source repository changes, setup updates the existing cache’s `origin` before fetching; `-buildvcs=false` removes SHA dependence on Git tags and history depth. CLI `-version` prints `(devel)`; the exact source is recorded in the release stamp and asset metadata

Rebuilding OlcRTC requires official, unpatched Go 1.27.3 and NDK 28.0.13004108.
`nix develop` provides official Go through `FLCLASHM_OLCRTC_GO`; outside that
environment, set the variable to the official `go` executable if it is not on `PATH`.
Preparation rejects nixpkgs patches in `net`/`mime`: they embed store paths and change
SHA-256. The official archive itself may reside in the Nix store. The stamp includes
`toolchain:official` and `buildid=none`; BuildID is disabled because Go includes
the C compiler path even with `-trimpath`. SHA-256 pins the bytes of each ABI.

The update preserves OLC2, handshake v3 and OLVC 5. Matching format versions does not
replace testing an old server with the new client through the required service. New
services require server support. Before release, test cold start, reconnection and VPN
on physical Android ABIs. See the [audit and verification notes](#olcrtc-audit).

By the accepted decision, Ghostlane sources are integrated without fixes for the audit
findings. Known issues: unauthenticated switching of the ordered SEI stream and
unbounded `floor` traversal; server-side accumulation of session-accounting records
and no mandatory loopback bind for `/stats`. The last two apply to `srv` mode, which
the app does not start. Tampering with encrypted content and an attack through a live
SFU were not confirmed in the audit. Dependency updates or a successful build do not
establish that these limitations have been fixed.

OlcRTC was rebuilt with official Go 1.27.3 to fix
[GO-2026-6809](https://pkg.go.dev/vuln/GO-2026-6809) in certificate validation.
The third-party dependency graph did not change. This update does not resolve the
Ghostlane audit findings listed above.

Verification of the v0.12.1 update: VK Calls tests (including payload-type conflicts and
renegotiation), config/client/protect and local E2E passed with `-race` using FlClashM’s
pinned dependencies. Three Android ABIs were rebuilt; `setup.dart` with official Go
reproduced SHA-256, and a second run used the cache. On an Android 16 emulator,
the exact x86_64 binary ran `-version`, parsed the CNC config and correctly reported
a connection refusal from an unavailable local endpoint. A live VK connection and
the app’s full VPN path were not tested for this version.

Reproducibility verification after review: official Go from the archive and from the
flake, and NDK from its original archive and from nixpkgs, produced byte-identical
files for all three ABIs with `-buildid=`. Binaries contain no `/nix/store/` paths;
the patched-Go rejection check passes before the build starts.

Live verification on 2026-10-22 (previous commit `b8a6e12`, before v0.12.1):
with `vkcalls + vp8channel`, a Linux server and the exact bundled x86_64 binary
on an Android 16 emulator joined a real VK room. SOCKS with remote name resolution
returned HTTPS 200 from example.com, Cloudflare and raw.githubusercontent.com;
a 243,217-byte file transferred in 1.36 s and matched the direct download byte for
byte (SHA-256 `40d15ce858cf058cff92606001a29ee1689db88c121a2f0c283163a0d64a7375`).
TLS verification stayed enabled. The first run hit the test PC’s fake-IP DNS:
the server correctly rejected reserved addresses. The second run used a local
DNS-to-DoH bridge to Cloudflare that returned real public addresses; OlcRTC outbound
traffic checks were unchanged. MTS was excluded from live testing at the user’s
request. This run verifies the transport and Android executable, but not the app’s
full VPN path, physical ARM ABIs or operation on networks with allowlists.
Test rooms, keys and tokens are not stored in the repository.

- **Update:** change the pinned commit, rebuild the three Android ABIs with pinned Go 1.27.3 and NDK 28.0.13004108 via `dart setup.dart android --out runtime-assets`, update the pinned SHA-256 from the produced files, and rerun the command and tests.
- **Rollback:** restore `openlibrecommunity/olcrtc@f3ad8fb7c0d0fa981423f83269526fa94077c23d` together with its module locks, release metadata and Android artifacts. New-provider profiles will no longer be supported; existing profiles need no migration.

</details>

<a id="release"></a>

## 📦 Release and rollback

Version in `pubspec.yaml`: `MAJOR.MINOR.PATCH[-preN]+YYYYMMDDnn`. Breaking changes require MAJOR, features MINOR, fixes PATCH; include upstream’s user-visible effects. Every tag’s `versionCode` must strictly increase. Tag `v<versionName>` only on a commit merged into main; release `applicationId`: `com.makriq.flclash`.

Create `release/<version>`, move user-facing Unreleased items to a CHANGELOG section matching the future tag exactly, update the version and run checks. After PR/merge, tag and push. CI verifies APK/AAB signatures and publishes universal/ABI APKs, AAB, SHA-256 and `FlClashM-android-release-metadata.json`. Prereleases appear in the app only when enabled in settings.

SourceForge is primary, GitHub is fallback. The stable/pre pointers below are verified against `.sig` with Ed25519 before JSON parsing. Each APK is checked by SHA-256, then Android verifies the package signature. Provider headers do not affect update trust.

The published manifest stores the overall `versionCode` and, per APK, `urls` (ordered mirrors), `size` (bytes), `sha256` and the actual `versionCode`. A stable release must include separate `.sha256` files for its assets.

```text
https://flclashm.sourceforge.io/update/stable.json
https://flclashm.sourceforge.io/update/pre.json
```

<details>
<summary>Publishing and downgrade protection</summary>

Publish `releases/<tag>` files first, then the pointer signature, then JSON last. Required secrets: `APP_UPDATE_SIGNING_KEY`, `SOURCEFORGE_SSH_KEY`, `SOURCEFORGE_USERNAME`. Extract APK codes using Android SDK: Flutter adds ABI offsets with `--split-per-abi`. The manifest code is the highest actual APK code; GitHub uses the same metadata codes.

Highest versionCode and publication time are stored per channel. Older signed manifests are rejected, and Android blocks APK downgrades. Roll back with a new corrective release carrying a higher code. Key rotation first requires a transitional app release containing the new public key.

</details>

Generate Flutter/Drift/Riverpod code with `nix develop -c make generate`. `tool/generate_flutter.dart` builds a real Flutter SDK summary using `sky_engine/_embedder.yaml` before running build_runner. This handles Nix resolving Flutter Dart to a standalone SDK without modifying the shared pub cache. Use the wrapper again after `build_runner clean`.
