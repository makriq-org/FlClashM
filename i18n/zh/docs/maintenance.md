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

独立诊断安装：在 `flutter build apk --debug --target-platform android-arm64` 前设置 `ORG_GRADLE_PROJECT_backendDiagnostic=true`。包名为 `com.makriq.flclash.backendcheck`；CI 的 `backend_test` 使用 `.backendtest`。保留数据更新：`adb install -r -t`。

简化的本地测试变体构建：准备内核和资源后运行 `ORG_GRADLE_PROJECT_backendTest=true flutter build apk --release --target-platform android-arm64`；包名为 `com.makriq.flclash.backendtest`。CI 还传入 `--dart-define=APP_ENV=pre` 和 `--dart-define=CORE_VERSION`，后者的值来自 `lib/core_version.dart`。

</details>

CI 覆盖 Go 主机/竞态、Dart/Flutter、Kotlin 单元测试、ARM64/armeabi-v7a 构建和 x86_64 E2E，使用真实 mihomo、validator、ByeDPI 和 TUN。纯文档修改跳过重任务。模拟器不能替代 ARM 真机：发布前检查模式、节点、订阅、UI/`:remote` 进程死亡、恢复时保留 Stop、网络切换及耗电。未解决问题见 [#132](https://github.com/makriq-org/FlClashM/issues/132)。`secret-scan` 工作流使用 Gitleaks 检查 PR 和推送提交。

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

基础代码通过 `tool/product_touchpoints.json` 调用 `lib/product/**`；组件登记在 `allowedProductUi`。`lib/views/**` 保留于基础层，仅添加少量钩子。其他基础修改需在 `tool/base_drift_allowlist.json` 说明原因。不要将协调逻辑或作为状态来源的旧 SharedPreferences 放回 Dart/Kotlin。

<details>
<summary>修改运行时须保持的后端约定</summary>

**Desired** 为已保存意图；**Applied** 为最后确认计划；**Observed** 为实际观测，出错时为 unknown。不可变 RuntimePlan 以版本和 SHA-256 校验。准备与效果队列分离；context 和代次阻止迟到结果生效。失败时恢复确认计划或停止资源。VPN 撤销会保存 Stop，必须再次显式 Start。队列最多接受 8 条命令，并为 Stop 保留额外容量。

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

从目标分支创建工作分支，执行下列命令并解决冲突。Dart 包名保持 `flclashx`。合并后立即检查 base drift，新路径须说明原因。无 upstream 时使用 `--merge-base=<sha>` 或 `BASE_DRIFT_MERGE_BASE`。运行时修改先以 `-preN` 发布并在 Android 真机验证。

```bash
git fetch upstream
git fetch origin
git merge upstream/dev
nix develop -c make check go-check
```

`tool/prepare_core.sh` 重建 `core/vendor`，无 fuzz 应用补丁并检查 Mieru 回归。构建使用 `-mod=vendor`，不修改共享模块缓存。补丁涉及 Mieru 已关闭 QUIC 超时、后端 HTTP 命令入口和系统 DNS 访问同步。更新时逐一检查；上游修复后删除对应补丁及调用，为其余补丁保留 vendor。

节点版本、源码提交、ABI 和 SHA-256 固定在 `lib/product/runtime/*_release.dart`；依赖见 [tool/runtime_go_modules](../../../tool/runtime_go_modules/README.md)，构建说明见[资源目录](../../../assets/runtimes/)。升级和回滚应同时调整固定版本、依赖与二进制，然后重建并验证发布 ABI。

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
