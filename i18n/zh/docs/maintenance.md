# 🛠 构建与维护

[← README](../README.md) · [Русский](../../ru/docs/maintenance.md) · [English](../../en/docs/maintenance.md) · **中文** · [فارسی](../../fa/docs/maintenance.md)

仓库常用命令，以及修改时必须保持的约定。分支、提交和 PR 规则见 [AGENTS.md](../../../AGENTS.md)。

[构建](#build) · [架构](#architecture) · [数据](#data) · [安全](#security) · [诊断](#diagnostics) · [上游](#upstream) · [发布](#release)

<a id="build"></a>

## 🏗 构建与检查

NixOS 环境在 `flake.nix` 中声明：Flutter 3.47.x、Go 1.27.2、JDK 17、SDK 37.0、NDK 28.0.13004108/28.2.13676358。环境配置应以声明方式修改。

```bash
nix develop -c make dev
nix develop -c make check
nix develop -c make go-check
```

`make check` 检查 product/base、GitHub Actions、发布连续性、`test/product`/`test/tool`、整个 `lib` 的错误（`analyze-app`）及定向分析。`make go-check` 准备 vendor，对 `core/backend` 检查 gofmt，然后以 `GOFLAGS=-mod=vendor` 对整个 `core` 执行 vet、主机测试和竞态检测，需要 C 编译器。APK：`build/app/outputs/flutter-apk/app-debug.apk`。

<details>
<summary>不用 Nix 与独立测试安装</summary>

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --debug --target-platform android-arm64
```

独立诊断安装：在 `flutter build apk --debug --target-platform android-arm64` 前设置 `ORG_GRADLE_PROJECT_backendDiagnostic=true`。包名为 `com.makriq.flclash.backendcheck`；手动 CI 的 `backend_test` 使用 `.backendtest`。保留数据更新：`adb install -r -t`。

简化的本地测试变体构建：准备内核和资源后运行 `ORG_GRADLE_PROJECT_backendTest=true flutter build apk --release --target-platform android-arm64`；包名为 `com.makriq.flclash.backendtest`。CI 还传入 `--dart-define=APP_ENV=pre` 和 `--dart-define=CORE_VERSION`，后者的值来自 `lib/core_version.dart`。

</details>

CI 覆盖 Go 主机/竞态、Dart/Flutter、Kotlin 单元测试、ARM64/armeabi-v7a 构建和 x86_64 E2E，使用真实 mihomo、validator、ByeDPI 和 TUN。纯文档修改跳过重任务。UI/backend Dart 桥接修改会触发使用真实 Flutter activity 的 E2E；instrumentation 错误和未处理的 Flutter 异常会导致检查失败。模拟器不能替代 ARM 真机：发布前检查模式、节点、订阅、UI/`:remote` 进程死亡、恢复时保留 Stop、网络切换及耗电。未解决问题见 [#132](https://github.com/makriq-org/FlClashM/issues/132)。`secret-scan` 工作流使用 Gitleaks 检查 PR 和推送提交。

<a id="architecture"></a>

## 🧭 架构

```text
RawProfile + Settings + Capabilities
  → Go Compiler + SecurityPolicy
  → immutable RuntimePlan
  → RuntimeCoordinator
  → mihomo / external processes / Android VPN
```

Flutter 负责展示和草稿，发送命令并读取快照。`core/backend/**` 负责配置、设置、订阅、编译和恢复；该可移植包可脱离 Android 测试。`core/backend_host.go` 连接 mihomo 和独立传输进程。Android 提供权限、前台服务、VPN/TUN、DNS 和系统事件。

RuntimeCoordinator 是可变运行状态的唯一所有者。后端独立于 Flutter 运行于 `:remote`；`:validator` 隔离 mihomo 解析器。`ui.attach` 可在未启用 VPN 时提前准备普通节点。Stop 在执行效果前保存，取消准备并关闭 VPN；UI 开启时已就绪节点可保留用于延迟测试。Stop 后无界面恢复不会启动它们；reset 和 Close 停止所有进程。

后端实例更换或 Binder 连接恢复时，仍在运行的 UI 使用新的 `operationId` 和 `restore: true` 再次发送 `ui.attach`。Go 恢复 UI 会话和节点准备，不会再次执行 `autoRun`；显式 Stop 后的停止意图保持不变。不带 `restore` 的首次打开使用正常的 `autoRun` 策略。

基础代码通过 `tool/product_touchpoints.json` 调用 `lib/product/**`；组件登记在 `allowedProductUi`。现有页面保留在 `lib/views/**`，不要在 product 中复制；可根据 FlClashM 架构演进，同时遵守 guards 和 allowlist，并将与 product 的连接登记为 touchpoints。受检查的基础修改需在 `tool/base_drift_allowlist.json` 说明原因；touchpoint 不能替代该记录。不要将协调逻辑或作为状态来源的旧 SharedPreferences 放回 Dart/Kotlin。

<details>
<summary>修改运行时须保持的后端约定</summary>

**Desired** 为已保存意图；**Applied** 为最后确认计划；**Observed** 为实际观测，无法确认状态时为 unknown。不可变 RuntimePlan 以版本和 SHA-256 校验。准备与效果队列分离；context 和代次阻止迟到结果生效。失败时恢复确认计划或停止资源。VPN 撤销会保存 Stop，必须再次显式 Start。队列最多接受 8 条命令，并为 Stop 保留额外容量。

API、数据和计划独立版本化，当前均为 `1`。请求：`apiVersion`、`operationId`、`method`、`params`；响应：`result` 或 `error`。相同 ID 和内容返回旧结果，内容不同则拒绝。需等待领域操作及其关联的 `runtimeOperationId`。超时或 UI 死亡不会取消工作；取消必须显式执行。

主要方法：`snapshot`、`runtime.view`、`presentation`、`runtime.*`、`operation.get/cancel`、`settings.patch`、`profile.*`、`subscription.refresh`、`proxy.select`、`backup.export/restore`、`blob.*`、`engine.command`、`ui.attach`、`data.reset`。事件携带 `instanceId`/sequence，溢出需 resync。UI 先订阅后读取快照，并显示 `runtime.view` 中已应用的选择。慢订阅者不阻塞 VPN。

</details>

<a id="data"></a>

## 💾 数据完整性

`backend-v1.json` 保存运行意图、代次、确认的 input/plan 和运行回执；`application-v1.json` 保存领域操作日志（最多 2 MiB）；`profiles.json` 保存配置目录和设置。这三个文件均通过原子重命名及 fsync 写入。恢复使用最后确认输入，未完成操作标为 interrupted。修订号阻止订阅或编辑器迟到写入。一次性迁移保留 ID、日期、原始字节、未知字段及大整数。

ZIP 保留 `config.json`、原始配置和 provider 缓存，缺失源文件不会被空文件替换。拒绝路径穿越、符号链接和 ZIP 炸弹。Binder 传输：192 KiB 分块，单文件最大 128 MiB，最多 32 个未完成传输，总计 512 MiB。删除最后一个配置会保存 Stop；reset 停止工作并保留迁移标记与单调代次。

Go 无需 UI 即可更新订阅及应用列表，网络失败时保留旧缓存。订阅到期通知阈值为 3/2/1/0 天及已过期；Go 持久保存去重状态，Android 本地化显示。

<a id="security"></a>

## 🔒 安全边界

可信 host 提供可执行文件路径、应用目录、ABI、证书和本地端口。节点端口被占用时在启动前拒绝。参数不经 shell，SOCKS 仅监听回环；Linux/Android 在主进程死亡时终止子进程。普通、dev 和测试包绕过 VPN，使用不同端口范围。Go SecurityPolicy 在验证和封装计划前执行。保留用户的 VPN 选择；`androidsecure` 仅关闭 mixed-port。

JS 在 Goja 中运行，无主机绑定，支持 deadline/cancel。公共列表和探测限制见[配置指南](profiles.md#checks)；允许私有订阅与应用列表服务器。HTTP 控制器在命令前检查 secret；任意配置路径、升级和旧运行时 setter 被阻止。DocumentsProvider 不公开内部日志和可执行产物。

<a id="diagnostics"></a>

## 🩺 诊断

没有遥测。日志页导出按钮生成 Dart、Android、mihomo 和节点日志 ZIP，包含 `manifest.json`（版本、Android API/ABI、时间及最小状态）。不包含配置、订阅、配置内容或 IPC payload。秘密、凭据、订阅 URL 和配置名称在写入前及导出时均会清除。

队列与轮转限制写入，慢日志不阻塞节点停止。Android 单行最多 16 KiB，Go 为 4 KiB、16 行队列。mihomo 无 Flutter 监听者也记录日志。`:remote` 不可用时仍能导出；ZIP 有 `schemaVersion`，脱敏通过 Dart/Kotlin 共同测试向量验证。

<a id="upstream"></a>

## 🔄 更新上游与节点

独立 Go backend 的架构和可靠性优先于尽量减少与上游的差异。选择性移植修复和功能；评估收益、冲突和运行时影响后再决定是否完整合并。保留 Flutter ↔ backend 和 base ↔ product 边界。

从目标分支创建工作分支。fetch 后明确选择上游 ref（分支或标签），在工作说明或 PR 中记录完整 SHA，然后移植选定修改，或有充分理由地合并该 SHA。我们的 Dart 包名为 `flclashx`；检查上游包名（例如 `fl_clash`），必要时调整导入和代码生成。

立即运行 `dart tool/check_base_drift.dart --upstream-ref=<upstream-sha>`，相对于选定 SHA 检查差异。也可通过 `--merge-base=<sha>` 或 `BASE_DRIFT_MERGE_BASE` 指定共同祖先。guards、touchpoints 和 allowlist 仍为强制要求：受检查的新 base 路径须在 allowlist 中说明原因，连接 product 还须登记 touchpoint。当前 `make check` 和 CI 默认相对于 `upstream/dev` 检查差异；选定 SHA 的检查不能替代它们。修改 CI 基准或规则需要单独实现。运行时修改先以 `-preN` 发布并在 Android 真机验证。

```bash
git fetch upstream
git fetch origin
nix develop -c make check go-check
```

`tool/prepare_core.sh` 重建 `core/vendor`，无 fuzz 应用补丁并检查 Mieru 回归。构建使用 `-mod=vendor`，不修改共享模块缓存。补丁涉及 Mieru 已关闭 QUIC 超时、后端 HTTP 命令入口和系统 DNS 访问同步。更新时逐一检查；上游修复后删除对应补丁及调用，为其余补丁保留 vendor。

节点版本、源码提交、ABI 和 SHA-256 固定在 `lib/product/runtime/*_release.dart`；依赖见 [tool/runtime_go_modules](../../../tool/runtime_go_modules/README.md)，构建说明见[资源目录](../../../assets/runtimes/)。升级和回滚应同时调整固定版本、依赖与二进制，然后重建并验证发布 ABI。

<a id="olcrtc-audit"></a>

<details>
<summary>OlcRTC：源码、构建与限制</summary>

- 使用 `ghostlane-project/olcrtc` 的 `proofkit` 分支、v0.12.1、提交 `b2c4b17ee35bfe65330aa9141f94dac082228bb2`；构建源码时不添加本地补丁
- v0.12.1 修复了 VK Calls 在连接和重新协商期间的 RTP payload type 冲突；依赖和配置格式保持不变
- 新增提供者：`vkcalls` 支持 `vp8channel` 或 `videochannel`，`mtslink` 支持 `vp8channel`，`salutejazz` 和 `max` 支持 `datachannel`。`max` 必须提供 `provider-token`，访客 `vkcalls` 禁止非空令牌。新引擎通过提供者选择，因为它们需要直接 `engine-url`/`engine-token` 契约中没有的额外凭据
- FlClashM 配置不公开 Ghostlane 新增的 UDP/direct/failover/DTLS 设置：保留 CNC、loopback SOCKS、Go 对 runtime 的独占管理和现有 Mihomo 路由
- 依赖仍固定在 `tool/runtime_go_modules/olcrtc.mod/.sum`，包含 FlClashM 的安全更新；新增固定版本的 `covert-dtls`，但不启用其伪装配置
- 源码仓库改变时，setup 在 fetch 前更新现有缓存的 `origin`；`-buildvcs=false` 消除了 Git 标签和历史深度对 SHA 的影响。CLI `-version` 显示 `(devel)`；准确源码版本记录在发布戳记和资源元数据中

重建 OlcRTC 必须使用未经修改的官方 Go 1.27.3 和 NDK 28.0.13004108。
`nix develop` 通过 `FLCLASHM_OLCRTC_GO` 提供官方 Go；在其他环境中，
如果官方 `go` 不在 `PATH`，请将此变量设为其路径。
准备流程会拒绝 nixpkgs 对 `net`/`mime` 的补丁，因为它们嵌入 store 路径并改变 SHA-256。
官方归档本身可以存放在 Nix store 中。戳记包含 `toolchain:official` 和 `buildid=none`；
禁用 BuildID 是因为即使启用 `-trimpath`，Go 仍会将 C 编译器路径放入其中。
SHA-256 固定各 ABI 的产物字节。

本次更新保留 OLC2、handshake v3 和 OLVC 5。格式版本相同不能替代通过所需服务
测试旧服务器与新客户端的兼容性。新服务需要服务器支持。
发布前应在真实 Android ABI 上验证冷启动、重连和 VPN。
参见[审计和验证记录](#olcrtc-audit)。

按照已接受的决定，Ghostlane 源码集成时没有修复审计发现。
已知问题包括：未经身份验证即可切换有序 SEI 流、无界的 `floor` 遍历、
服务器会话记账记录不断累积，以及 `/stats` 不强制绑定 loopback。
后两项属于应用不会启动的 `srv` 模式。审计没有证实篡改加密内容或通过真实 SFU
发动攻击的可行性。依赖更新或构建成功不代表这些限制已得到修复。

OlcRTC 已使用官方 Go 1.27.3 重建，以修复证书验证中的
[GO-2026-6809](https://pkg.go.dev/vuln/GO-2026-6809)。
第三方依赖图没有改变。本次更新不会修复上述 Ghostlane 审计问题。

v0.12.1 更新验证：使用 FlClashM 固定依赖，VK Calls 测试（包括 payload type 冲突和
重新协商）、config/client/protect 及本地 E2E 均通过 `-race`。
三个 Android ABI 已重建；`setup.dart` 使用官方 Go 复现了 SHA-256，第二次运行使用缓存。
在 Android 16 模拟器上，随附的准确 x86_64 二进制执行了 `-version`、解析了 CNC 配置，
并按预期报告无法连接到不可用的本地端点。此版本尚未验证真实 VK 连接或应用的完整 VPN 路径。

审查后的可复现性验证：分别使用官方归档和 flake 中的官方 Go，以及原始归档和 nixpkgs
中的 NDK，配合 `-buildid=`，三个 ABI 的产物均逐字节相同。
二进制不包含 `/nix/store/` 路径；拒绝带补丁 Go 的检查在构建启动前通过。

2026-10-22 的真实连接验证（之前的提交 `b8a6e12`，早于 v0.12.1）：
使用 `vkcalls + vp8channel`，Linux 服务器和 Android 16 模拟器上随附的准确 x86_64
二进制加入了真实 VK 房间。通过 SOCKS 远程解析域名，从 example.com、Cloudflare 和
raw.githubusercontent.com 获得 HTTPS 200；243,217 字节文件在 1.36 秒内传输完成，
与直接下载逐字节相同（SHA-256
`40d15ce858cf058cff92606001a29ee1689db88c121a2f0c283163a0d64a7375`）。
TLS 验证保持启用。首次运行遇到了测试电脑的 fake-IP DNS，服务器正确拒绝了保留地址。
第二次运行使用连接 Cloudflare 的本地 DNS-to-DoH 桥，返回真实公网地址；
没有更改 OlcRTC 出站流量检查。按用户决定，MTS 未纳入真实连接验证。
此轮验证确认了传输和 Android 可执行文件，但未确认应用的完整 VPN 路径、
真实 ARM ABI 或在白名单网络中的运行情况。测试房间、密钥和令牌不存入仓库。

- **更新：** 更换固定提交，用固定的 Go 1.27.3 和 NDK 28.0.13004108 经 `dart setup.dart android --out runtime-assets` 重建三个 Android ABI，按产物更新固定的 SHA-256，并重跑该命令与测试。
- **回滚：** 恢复 `openlibrecommunity/olcrtc@f3ad8fb7c0d0fa981423f83269526fa94077c23d`，以及对应的模块锁定文件、发布元数据和 Android 产物。新服务的配置将不再受支持；已有配置无需迁移。

</details>

<a id="release"></a>

## 📦 发布与回滚

`pubspec.yaml` 版本：`MAJOR.MINOR.PATCH[-preN]+YYYYMMDDnn`。不兼容修改升 MAJOR，功能升 MINOR，修复升 PATCH，也需考虑上游对用户的影响。每个标签的 `versionCode` 必须严格递增。`v<versionName>` 标签仅打在已合入 main 的提交上；发布 `applicationId` 为 `com.makriq.flclash`。

创建 `release/<version>`，将 Unreleased 中面向用户的条目移入与未来标签完全一致的 CHANGELOG 小节，更新版本并检查。PR 合并后打标签并推送。CI 验证 APK/AAB 签名，发布 universal/各 ABI APK、AAB、SHA-256 和 `FlClashM-android-release-metadata.json`。应用仅在设置开启后显示预发布。

SourceForge 为主源，GitHub 为备用。下列 stable/pre 指针在解析 JSON 前通过 Ed25519 验证 `.sig`。各 APK 先校验 SHA-256，再由 Android 验证包签名。提供商响应头不影响更新信任。

发布目录保存总体 `versionCode`，每个 APK 保存 `urls`（按顺序排列的镜像）、`size`（字节）、`sha256` 和实际 `versionCode`。稳定版必须提供各产物独立的 `.sha256` 文件。

```text
https://flclashm.sourceforge.io/update/stable.json
https://flclashm.sourceforge.io/update/pre.json
```

<details>
<summary>发布与防降级</summary>

先发布 `releases/<tag>` 文件，再发布指针签名，最后发布 JSON。所需秘密：`APP_UPDATE_SIGNING_KEY`、`SOURCEFORGE_SSH_KEY`、`SOURCEFORGE_USERNAME`。用 Android SDK 提取 APK 编号：Flutter 的 `--split-per-abi` 会加入 ABI 偏移。目录编号取实际 APK 编号最大值；GitHub 使用相同 metadata 编号。

各渠道分别保存最高 versionCode 和发布时间。旧的已签名目录会被拒绝，Android 也禁止 APK 降级。回滚通过编号更高的修正版本完成。轮换密钥时，先发布含新公钥的过渡版本。

</details>
