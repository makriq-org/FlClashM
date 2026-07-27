# ⚙️ 运行时

## 🔗 处理流水线

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan
```

此后由 `EngineManager` 与 `EngineAdapter` 管理生命周期。

---

## 🔍 内置节点验证

启动 NaiveProxy、OlcRTC、ByeDPI 和 StormDNS 分**两个阶段**：

1. ✅ 确认存活的进程与本地 SOCKS 端口；
2. 🌐 严格经该 SOCKS 端口发起端到端 HTTP(S) 请求。

产品层校验并序列化来自 `lib/product/runtime/connectivity_check.dart` 的契约，由 Android 服务经 `RuntimeNodeConnectivityChecker` 执行。

**事务性。** 必需检查属于启动事务：`startup-timeout` 耗尽会停止新节点并回滚已准备的方案。可选检查在后台进行，仅影响日志。已保存的清单携带相同契约，Android 平台层在 always-on 恢复时会在内核快速启动前执行它 —— 因此**正常启动与冷启动的成功条件一致**。

**无直接回退连接。** 名称在 SOCKS 请求之前解析，所有解析出的地址必须是公网，SOCKS 命令收到的是已验证的 IP。TLS 会针对原始名称校验证书。

**进程所有权。** Android 服务是工作进程与 ByeDPI 临时策略选择进程的唯一所有者。单次 `probeRuntimeNode` 与工作方案的替换串行化；批量调用仅在检查快照时持锁，不会在网络请求期间阻塞方案替换。两条路径都要求强制安全检查、始终终止临时进程，且不改变生效或已保存的方案。失败的候选被丢弃；回滚使用旧缓存，若无则使用内置回退策略。该路径的更新对 Dart 桥、AIDL 与 Android 服务一并进行；回退到旧版本无需迁移缓存数据。

**自动选择（批量）。** Android 服务在不同 loopback 端口上启动有限数量的候选，返回第一个成功者并取消其余。单个候选执行一轮 HTTP(S) 请求，不重试、不将给定超时翻倍。Dart 用单调的总预算限制前台阶段；之后启动 fallback 并在后台继续列表。成功的后台结果会原子地提升为已验证缓存、重新应用完整运行时方案并更新冷启动清单。方案替换通过 generation token 取消后续处理，而 Android 始终完成已启动的批次。

---

## 🧩 内置节点

内置节点在配置中声明为普通代理，其生命周期由 `BuiltInProxySupervisor` 管理。

> 📎 面向用户的一侧（YAML、参数）见[内置节点指南](../user-guide/profiles.md)。

### 🎭 naiveproxy

- **类型：** `naiveproxy`
- **必填字段：** `name`、`type`、`server`、`port`、`username`、`password`
- 仅允许 `https` 和 `quic` 传输；禁止匿名访问
- 不支持 UDP；最终的本地 `mihomo` 节点得到 `udp: false`
- 客户端自行选择本地 SOCKS5 地址
- 编译器转义凭据、构造唯一的内部 URI，并以自动生成的 `config.json` 启动 NaiveProxy
- 白名单拒绝 `proxy`、`listen`、诊断文件、代理链及未知字段

### 📞 olcrtc

- **类型：** `olcrtc`
- **必填字段：** `name`、`auth.provider`、`room.id`（`none` 除外）、`crypto.key`、`net.transport`、`net.dns`
- 仅在 CNC（客户端）模式工作
- 不支持 UDP；最终的本地 `mihomo` 节点得到 `udp: false`
- 启动前 FlClashM 校验必填字段、允许的提供者与传输、密钥、DNS 以及每个最终备用 profile
- Android 服务保留有限的进程输出尾部；若 OlcRTC 在打开 SOCKS5 端口前退出，原因会立即回传给 Dart 并显示给用户
- 通过稳定的 `config.yaml` 契约以独立进程运行；不使用移动库
- 源码固定在提交 `ad5758513335cda54362a64621c29e9d9fe759b4`
- CLI 需要 `data: data`，但无需单独的目录布局：名称字典已嵌入可执行文件，缺失的外部文件视为可选覆盖
- 每个二进制的 SHA-256 固定在提交旁；资源准备与测试即使在戳记匹配时也会拒绝过时或被改动的文件

<details>
<summary>🔧 olcrtc 的更新与回滚</summary>

- **更新：** 更换固定提交，用固定的 Go 1.26.4 和 NDK 28.0.13004108 经 `dart setup.dart android --out runtime-assets` 重建三个 Android ABI，按产物更新固定的 SHA-256，并重跑该命令与测试。
- **回滚：** 恢复旧提交 `5dd6822d807e3352fe4452a3b071e043d958a020`，并用同一命令重建产物。

</details>

### 🌩 stormdns

- **类型：** `stormdns`
- **必填字段：** `name`、`type`、`domains`、`encryption`、`encryption-key`
- 必填字段没有默认值：StormDNS 不做协议协商，取值必须与服务端一致
- 不支持 UDP；生成的本地 `mihomo` 节点会得到 `udp: false`
- 本地 SOCKS5 端口从 36200 起的范围内分配
- 预设 `messenger` / `balanced` / `bulk` 设定复制与压缩；叠加顺序为 **StormDNS 默认值 → preset → 显式字段**
- 模式取值范围取自 StormDNS 的 `finalizeClientConfig`：上游会静默截断的取值一律在启动前拒绝，包括相互关联的边界（`upload-setup` ≥ `upload`、`download-setup` ≥ `download`、max MTU ≥ min、`nack-max-gap` ≤ `window/4`、RTO 与 ping 间隔的顺序）
- 源码固定在提交 `87348df5b11f9e490262a713ca268734007af44f`
- 每个二进制文件的 SHA-256 与提交一并固定；即使标记一致，资源准备与测试也会拒绝过期或被修改的文件

<details>
<summary>🔧 stormdns 的升级与回滚</summary>

- **升级：** 更换固定提交，使用固定的 Go 1.26.4 与 NDK 28.0.13004108 执行 `dart setup.dart android --out runtime-assets` 重新构建三个 Android ABI，按产出文件更新固定的 SHA-256，然后重新执行该命令与测试。
- **回滚：** 该节点为首次内置，没有上一个固定提交。版本回滚即恢复提交并以同样方式重新构建；对用户而言的应急回滚是把该节点从配置中移除。无需数据迁移：工作缓存按 fingerprint 归属，会自动重建。

</details>

**解析器文件。** Android 启动契约以**通用方式扩展，不做节点类型判断**：节点声明 `resolverFile`，包含 `template`、`path`、`dependsOnSystemDns` 与 `resetPaths`。配置只投放模板（`client_resolvers.template`），进程真正读取的文件（`client_resolvers.txt`）由平台生成 —— 因此平台的重写不会被当作配置变更，也不会在每次应用配置时重启节点。系统 DNS 变化时，`RuntimeNodeResolverFile` 原子地重新生成该文件，重置 `resetPaths` 中的路径，并**只重启处于活动状态的依赖**节点。`SystemDnsReader` 自行读取系统 DNS，因为冷启动会在 `NetworkObserveModule` 安装之前就应用计划。

**多产物事务。** `LocalNodeController` 通过 stage → rollback → commit 为单个节点管理多个文件。单文件节点的修订逻辑逐字节保持不变，因此 NaiveProxy、OlcRTC 与 ByeDPI 的行为没有变化。工作缓存以最终解析器列表、`domains` 与 StormDNS 版本的 fingerprint 为键；旧目录只在 commit 成功**之后**才删除，回滚会恢复上一份计划的状态。

**有意偏离上游之处。** StormDNS 的 `usableHostCount` 对 IPv4 `/1` 返回 2，随后却遍历 2³¹ 个地址。FlClashM 计算实际展开规模，并按文档中的 65536 上限截断 —— 否则这样的配置会让应用卡死。

### 😴 `auto` 激活（olcrtc 与 stormdns）

supervisor 提前暂存休眠节点的产物，但不把它纳入 live 或冷启动清单，因此其必需的端到端检查不再属于 VPN 启动事务。watchdog 探测被观察分组，在设定的失败次数后唤醒备用节点，原子地应用完整方案，并强制刷新该节点自身的 delay。在所有直接包含分组均无连接与无选择一段时间后，方案会在不含该节点的情况下应用，进程重新休眠。配置变更或停止会通过 generation token 取消迁移；休眠状态不持久化，重启后重新开始。

对 `mihomo` 与网络状态的访问由 `RuntimeHealthProbe` 接口隔离：产品层只看到 delay 测试、活动连接链、分组当前的 `now` 以及网络存在与否。实现位于 app 层，构建在 `clashCore` 与 `connectivity_plus` 之上。没有注入 probe 时自动 watchdog 空转，但暂存、停止与手动唤醒仍然安全。`always` 模式不走此路径，保持旧的启动事务。

集成随应用的 Dart 部分一起更新，不改动 Android 桥；即时回滚为 `activation: always`，版本回退无需状态迁移。

### 🛡 byedpi

- **类型：** `byedpi`
- **`manual` 模式：** 接受 `args` 字符串
- **`auto` 模式：** 遍历 ByeByeDPI 策略并缓存可用的一条
- 无 `mode` 时，有 `args` 选手动，无 `args` 选自动
- auto 模式下 `strategy-list` 默认为 `byebyeedpi`；无 `strategy-test.urls` 时使用内置 YouTube 测试端点
- 支持 `{sni}` 替换
- 默认启用 UDP 并传给本地 `mihomo` 节点；`udp: false` 将其关闭，而 ByeDPI 进程本身不接收单独的 UDP 参数


---

## 🚧 限制

- 内置节点只能在 `proxies` 段工作
- 本地地址和端口由客户端决定
- `auto` 模式下的 ByeDPI 检查 `strategy-test.urls` 里的 URL 或内置 YouTube 端点
- StormDNS 天生较慢：冷启动包含对解析器的 MTU 扫描（真机上三个解析器耗时 28 秒），因此其默认 `startup-timeout` 提高到 120 秒

---

## 📸 Android VPN 应用参数快照

**在架构中的位置。** `FlVpnService` 仅在 `VpnService.Builder.establish()` 成功**之后**才把参数的不可变快照存入 `State.appliedOptions`，并通过独立的 AIDL/MethodChannel 契约 `getAppliedAndroidVpnOptions` 暴露。`AccessControlService` 将快照与当前配置的声明比对；基线屏幕只接收成品状态。

**契约与约束：**

- 空响应表示没有可用的已确认快照；
- 带 `includePackage: []` 或 `excludePackage: []` 的 JSON 保留带空列表的显式模式，不等于缺少规则；
- 普通的内核配置重载不会更新快照，因为 Android 包规则只在 VPN 重建时改变；
- 该通道只读，不影响路由；
- 快照不可用时，界面明确说明它显示的是**配置声明**，而不把它冒充为已应用状态。

**更新与回滚。** 通过新增方法完成，不触碰用于启动 VPN 的旧 `getAndroidVpnOptions`。回滚安全：旧启动路径保持不变，新响应缺失时映射为「验证不可用」状态。

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/runtime.md) · [English](../../../en/docs/development/runtime.md) · [فارسی](../../../fa/docs/development/runtime.md)
