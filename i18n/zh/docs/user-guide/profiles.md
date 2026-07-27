# 🧩 内置节点

FlClashM 的超能力：**特殊节点直接写在 YAML 配置里**，并表现得像普通代理。客户端负责启动进程、分配本地端口，并接入 `mihomo` 的路由。在规则里可以随意混用 —— 一个站点走 `byedpi`，另一个走 `olcrtc`，其余直连。

支持四种类型：

| 类型 | 作用 | 何时用得上 |
|------|------|-----------|
| 🛡 [`byedpi`](#-byedpi) | 通过数据包操纵绕过 DPI | 被「从内部」封锁的资源：YouTube、Discord 等 |
| 📞 [`olcrtc`](#-olcrtc) | 伪装成视频通话的 WebRTC 隧道 | 绕过白名单（如经 Yandex Telemost / Jitsi） |
| 🌩 [`stormdns`](#-stormdns) | 藏在 DNS 查询里的隧道 | 在只放行 DNS 的场景绕过白名单 |
| 🎭 [`naiveproxy`](#-naiveproxy) | 伪装成 Chrome 流量 | 绕过黑名单、抵抗 TLS 指纹识别 |

> ℹ️ 内置节点**只能**写在 `proxies` 段。本地地址和端口由客户端分配 —— 不能在配置里指定。

---

## 🔍 启动检查

在认定节点就绪之前，FlClashM 始终验证两件事：**存活的进程**和**打开的本地 SOCKS 端口**。这适用于 NaiveProxy、OlcRTC、ByeDPI 和 StormDNS。

在此之上还可开启**端到端检查** —— 一个严格经由该节点 SOCKS 端口的真实 HTTP(S) 请求：

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

| 字段 | 默认值 | 含义 |
|------|--------|------|
| `urls` | — | 要检查的地址（公网 HTTP(S)，不含凭据或片段） |
| `required` | `false` | 该检查是否为启动所必需 |
| `timeout` | `5` | 单次请求超时（秒） |
| `startup-timeout` | `30`（`stormdns` 为 `120`） | 启动时的总检查预算（秒） |
| `retry-interval` | `1` | 重试间隔（秒） |
| `requests` | `1` | 请求次数 |
| `concurrency` | `1` | 并行请求数 |
| `min-success-ratio` | — | 成功响应的最小比例（不设则一次成功即可） |

**地址如何选择。** 顺序为：节点自身的 `connectivity-check.urls` → 最近的包含分组的地址 → 应用的全局检查地址。若都没有，则只保留进程与端口检查。

> ⚠️ **`required: false` 与 `required: true` 的区别：**
> - `false` —— 检查在后台进行，不拖延启动，失败仅记入日志。
> - `true` —— 缺少地址会**拒绝**配置，检查失败会**取消**启动并回滚已准备的方案。
>
> **任何**合法 HTTP 响应都算成功，包括 `4xx` 和 `5xx`。只允许不含凭据或片段的公网 HTTP(S) 地址。

---

## 🛡 ByeDPI

**类型：** `byedpi` · 默认启用 UDP（用 `udp: false` 关闭）

ByeDPI 通过「破坏」数据包让过滤器无法识别连接，从而绕过 DPI。该节点有两种模式。

### 🤖 自动策略选择

客户端遍历 ByeByeDPI 列表中的策略，找到可用的一条并缓存 —— 冷启动时会立即取用。

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

工作方式：候选以小组并行检查。若在预算内未找到，节点先以临时（fallback）策略启动，其余列表在后台继续检查。找到的可用策略会原子地切入方案并保存。

<details>
<summary>⚙️ 自动模式全部参数</summary>

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `strategy-list` | `byebyeedpi` | 策略列表名 |
| `strategies` | — | 自定义有序参数列表，替代 `strategy-list` |
| `strategy-test.urls` | 内置 YouTube 端点 | 用于选择的地址 |
| `strategy-test.sni` | — | 替换 `{sni}` 的主机名 |
| `strategy-test.resolver` | `https://1.1.1.1/dns-query` | 解析测试地址的 DoH 解析器（绕过 fake-ip）；`system` 使用系统解析器 |
| `strategy-test.timeout` | `5` | 单次检查超时（秒） |
| `strategy-test.requests` | `1` | 每条策略的请求数 |
| `strategy-test.concurrency` | `4` | 单个候选内的并行 HTTP 请求数 |
| `strategy-test.min-success-ratio` | `1.0` | 成功请求的最小比例 |
| `selection.concurrency` | `4` | 同时检查的策略数 |
| `selection.foreground-timeout` | `15` | 节点启动前的选择预算（秒） |
| `selection.background` | `true` | fallback 后是否在后台继续检查列表 |
| `fallback-args` | — | 前台未及时完成时的临时策略参数 |
| `cache.ttl` | 7 天 | 缓存生存期（秒） |
| `cache.recheck-after` | 1 天 | 重新检查间隔（秒） |
| `cache.retry-after` | 5 分钟 | fallback 后再次选择前的暂停（秒） |
| `cache.failure-threshold` | `2` | 重置缓存前的错误次数 |

</details>

> ℹ️ `strategy-test` **仅**用于自动选择，并覆盖内置测试端点 —— 它不替代 `connectivity-check`。已验证结果与临时 fallback **分开**缓存：fallback 不会在正常 TTL 内阻断后续选择尝试。任何 HTTP 检查都算成功，包括 `4xx` 和 `5xx`。
>
> 🚫 旧的 `test` 段不再支持 —— 请改名为 `strategy-test`。

### ✍️ 手动策略

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

> 💡 若省略 `mode`：有 `args` 走**手动**模式，无 `args` 走**自动**模式。

---

## 📞 OlcRTC

**类型：** `olcrtc` · 不支持 UDP（仅允许 `udp: false`）

OlcRTC 把流量封装进 WebRTC，伪装成经由某个允许服务的普通视频通话 —— 于是连接得以穿过白名单。

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

| 参数 | 说明 |
|------|------|
| `auth.provider` | 连接提供者：`jitsi`、`telemost`、`wbstream`、`none` |
| `room.id` | 视频通话房间标识 |
| `crypto.key` | 256 位加密密钥 —— **恰好 64 个十六进制字符** |
| `net.transport` | 传输：`datachannel`、`vp8channel`、`seichannel`、`videochannel` |
| `net.dns` | 必填 DNS 服务器，格式 `地址:端口` |

> 💡 对 `wbstream` 推荐 `vp8channel`：该提供者的访客模式不授予发布数据通道的权限。可选的 `vp8.fps` 和 `vp8.batch_size` 默认为 `30` 和 `64`。

若设置了 `profiles`，顶层公共字段会被每个备用 profile 继承，FlClashM 会在启动前校验每个 profile 的最终配置。本地地址、SOCKS5 端口、CNC 模式和数据目录由客户端分配 —— 不能在配置里覆盖。

> ⚠️ 必填字段的错误在配置校验阶段即可发现。若 OlcRTC 进程稍后退出，客户端会显示**退出码和输出的最后几行**，而不是干等端口超时。

---

## 🌩 StormDNS

**类型：** `stormdns` · 不支持 UDP（只能 `udp: false`）

StormDNS 把 TCP 封装进发往允许解析器的普通 DNS 查询 —— 于是连接得以穿过白名单。目标与 OlcRTC 相同，载体不同 —— DNS：该节点面向只放行 DNS 查询的网络。它比其他节点**明显更慢**。

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

### 🔑 必填字段

`domains`、`encryption` 和 `encryption-key` **必填且没有默认值**：StormDNS 不做任何协商，这三项必须与服务端完全一致。

| 字段 | 说明 |
|------|------|
| `domains` | 委派给 StormDNS 服务端的域名 |
| `encryption` | `none`、`xor`、`chacha20`、`aes-128-gcm`、`aes-192-gcm`、`aes-256-gcm` |
| `encryption-key` | 共享密钥；必须与服务端一致 |

> ⚠️ `none` 和 `xor` 模式**不保护内容**，解析器运营方可以看到你的流量。仅在服务端要求时使用。

### 📍 解析器

`resolvers` 是一个统一的来源列表，按顺序处理：

| 条目 | 添加内容 |
|------|---------|
| `system` | 物理网络（非 VPN）的 DNS |
| `8.8.8.8` | 一个使用 53 端口的解析器 |
| `1.1.1.1:5353` | 一个使用自定端口的解析器 |
| `192.168.1.0/30` | CIDR：IPv4 会跳过网络地址与广播地址；超过 65536 个地址的范围会被拒绝 |
| `https://…` | 来自远程列表的解析器 |

未设置或为空的 `resolvers` 一律使用 `[system]`。所有来源展开后按 IP 去重：第一次出现的条目连同其端口胜出。若最终列表为空，配置不会被应用。

列表地址只允许 HTTPS，不得带凭据或锚点；禁止 localhost 与本地地址 —— 但列表**内部**的私有 IP 和 CIDR 是允许的。响应上限 1 MiB，超时 15 秒。每个地址单独缓存：地址不可达时即使已超过 `refresh` 也会使用上次保存的副本；若没有副本则跳过该地址，其余来源照常生效。

| `resolver-policy` | 默认值 | 说明 |
|-------------------|--------|------|
| `refresh` | `24h` | 远程列表的刷新周期 |
| `strategy` | `least-loss` | `random`、`round-robin`、`least-loss`、`lowest-latency` |
| `auto-disable` | `true` | 停用不再应答的解析器 |
| `recheck` | `true` | 定期重测已停用的解析器 |

`refresh` 在应用配置时检查 —— 没有常驻定时器。

### 🎚 预设

`preset` 决定数据包复制与压缩。叠加顺序：**StormDNS 默认值 → preset → 显式设置的字段**。

| `preset` | 复制次数（upload / download / upload-setup / download-setup） | 压缩 |
|----------|--------------------------------------------------------------|------|
| `messenger`（默认） | 1 / 7 / 3 / 8 | `lz4` |
| `balanced` | 2 / 5 / 3 / 6 | `lz4` |
| `bulk` | 3 / 3 / 4 / 4 | `zstd` |

任何字段都可以单独覆盖，无需额外语法：

```yaml
preset: bulk
duplication:
  upload: 2
compression:
  upload: zlib
```

精细调节位于 `duplication`、`compression`、`mtu`、`arq`、`ping` 和 `runtime` 块。在这些块以及 `resolver-policy`/`startup` 中，时长使用字符串（`600ms`、`30s`、`24h`、`30d`）。通用字段 `activation` 和 `connectivity-check` 仍使用整数秒。

> ℹ️ StormDNS 会静默截断超出范围的值。FlClashM 则在**启动前直接报错**。

<details>
<summary>📐 精细调节的取值范围</summary>

| 块 | 字段与范围 |
|----|-----------|
| `duplication` | `upload`、`download`、`upload-setup`、`download-setup` —— 1…8 |
| `compression` | `upload`、`download` —— `none`、`zstd`、`lz4`、`zlib`；`min-size` —— 100…65535 |
| `mtu.upload`、`mtu.download` | `min` —— 1…65535；`max` —— 0…65535，其中 `0` 表示不设上限 |
| `arq` | `window` 1…6000、`nack-max-gap` 0…1500、`max-control-retries` 5…5000、`max-data-retries` 60…100000；其余字段为时长 |
| `ping` | 仅时长：`aggressive`/`lazy`/`cooldown`/`cold` 间隔与 `warm`/`cool`/`cold` 阈值 |
| `runtime` | `workers` 与 `process-workers` 1…64、队列与池大小、重试时长；`base-encode` 为布尔标志 |

关联约束会被完整校验：

- `duplication.upload-setup` ≥ `upload`、`download-setup` ≥ `download`
- `mtu.<方向>.max` ≥ `min`
- `arq.initial-rto` ≤ `max-rto`、`arq.control-initial-rto` ≤ `control-max-rto`
- `arq.nack-max-gap` ≤ `arq.window / 4`
- `ping.aggressive-interval` ≤ `lazy-interval` ≤ `cooldown-interval` ≤ `cold-interval`
- `ping.warm-threshold` ≤ `cool-threshold` ≤ `cold-threshold`
- `runtime.process-workers` ≥ `runtime.workers`
- `runtime.session-retry-base` ≤ `session-retry-max`

字段名与 StormDNS 配置一致。

</details>

### 🚀 启动

| `startup.mode` | 作用 |
|----------------|------|
| `scan` | 完整扫描解析器（启动最慢） |
| `cached`（默认） | 从缓存启动，不重测 MTU |
| `verified` | 从缓存启动并重测 MTU |

`startup.max-age`（默认 `30d`）限制可用缓存的最大年龄，并且必须是整数天。

> ⏳ 首次启动要经过解析器扫描，可能耗时长达两分钟 —— 检查预算已为此预留。

工作缓存与最终解析器列表、`domains` 以及 StormDNS 版本绑定。配置中的来源、`domains` 或版本发生变化时会生成新缓存，旧缓存仅在配置成功应用后才删除。物理网络 DNS 变化时，会在重启节点前清除当前缓存。若没有合适的缓存，或 StormDNS 判定其无效，它会自行回退到完整扫描 —— 这是正常行为。

日志目录、resolver 文件、本地端口和 SOCKS5 均由应用管理，无法在配置中指定。

### 📶 系统 DNS

当 `resolvers` 含有 `system`（或未设置）时，该节点依赖物理网络的 DNS。DNS 变化时，平台会自行重写 resolver 文件、重置工作缓存，并**仅**重启处于活动状态的依赖节点 —— 包括界面未运行的冷启动场景。无需额外的 bypass：应用自身的包已被排除在 VPN 路由之外。

---

## 🎭 NaiveProxy

**类型：** `naiveproxy` · 不支持 UDP（仅允许 `udp: false`）

NaiveProxy 利用 Chromium 的网络栈把流量伪装成普通 Chrome 请求 —— 这对 TLS 指纹识别与主动探测都有抵抗力。

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

- **必填字段：** `name`、`type`、`server`、`port`、`username`、`password`。
- `transport` 默认为 `https`；也允许 `quic`。
- 可选：`insecure-concurrency`（1–4）、`tunnel-timeout`、`idle-timeout`、`post-quantum`、`headers` 映射、`host-resolver-rules` 以及共享的 `connectivity-check`。

客户端会安全地构造带转义凭据的 URI，交给 NaiveProxy，并把用于 `mihomo` 的节点替换为本地 SOCKS5。

> 🚫 旧的 `proxy` 字段不再支持。`listen`、诊断文件、代理链以及任何未知字段都会在配置校验时被**拒绝**。

---

## 😴 激活：休眠备用（OlcRTC 与 StormDNS）

默认情况下 OlcRTC 与 StormDNS 作为**备用节点**：配置提前就绪，但进程处于休眠，直到主分组开始失败或用户手动选择该节点。

```yaml
activation: auto
# activation: always  # 旧模式：与 VPN 一同启动
```

完整形式可控制唤醒与休眠：

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

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `mode` | `auto` | `auto` 让备用节点休眠；`always` 为旧的常驻启动 |
| `wake.urls` | `connectivity-check` 链 | 用于探测被观察分组的公网 HTTP(S) 地址 |
| `wake.interval` | `30` | 休眠期间的探测间隔（秒） |
| `wake.failures` | `2` | 唤醒前连续失败的轮数 |
| `wake.retry-after` | `300` | 启动失败后的暂停（秒） |
| `sleep.idle` | `900` | 无连接与无选择直至休眠的时长；`0` 表示 VPN 重启前不休眠 |

**关于 `auto` 需要知道的：**
- 节点必须直接属于至少一个 proxy group。
- 检查地址须能从 `wake.urls`、节点的 `connectivity-check`、最近的分组或应用的全局测试 URL 解析出来。
- 唤醒后客户端会立即检查该节点本身。若没有任何包含分组选中它，且在 `sleep.idle` 内没有活动连接 —— 进程重新休眠。
- **手动选择会立即唤醒节点。**

> ℹ️ 现在**即使没有 `activation` 字段**也默认使用 `auto`。要完全恢复旧行为，请显式设置 `activation: always`。

---

## 🚧 限制

- 内置节点只能写在 `proxies` 段。
- 本地地址和端口由客户端管理。
- 配置不能设置本地 `listen`；NaiveProxy 的 `server` 和 `port` 仅描述远端服务器。
- UDP：`byedpi` —— 启用（可用 `udp: false` 关闭）；`naiveproxy`、`olcrtc` 和 `stormdns` **不**支持 UDP。

---

> 📎 节点生命周期的技术细节见[运行时](../development/runtime.md)。安全保证见[安全策略](../development/security.md)。
>
> 🌍 其他语言：[Русский](../../../ru/docs/user-guide/profiles.md) · [English](../../../en/docs/user-guide/profiles.md) · [فارسی](../../../fa/docs/user-guide/profiles.md)
