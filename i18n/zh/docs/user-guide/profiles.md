# 🧩 内置节点

FlClashM 的超能力：**特殊节点直接写在 YAML 配置里**，并表现得像普通代理。客户端负责启动进程、分配本地端口，并接入 `mihomo` 的路由。在规则里可以随意混用 —— 一个站点走 `byedpi`，另一个走 `olcrtc`，其余直连。

支持三种类型：

| 类型 | 作用 | 何时用得上 |
|------|------|-----------|
| 🛡 [`byedpi`](#-byedpi) | 通过数据包操纵绕过 DPI | 被「从内部」封锁的资源：YouTube、Discord 等 |
| 📞 [`olcrtc`](#-olcrtc) | 伪装成视频通话的 WebRTC 隧道 | 绕过白名单（如经 Yandex Telemost / Jitsi） |
| 🎭 [`naiveproxy`](#-naiveproxy) | 伪装成 Chrome 流量 | 绕过黑名单、抵抗 TLS 指纹识别 |

> ℹ️ 内置节点**只能**写在 `proxies` 段。本地地址和端口由客户端分配 —— 不能在配置里指定。

---

## 🔍 启动检查

在认定节点就绪之前，FlClashM 始终验证两件事：**存活的进程**和**打开的本地 SOCKS 端口**。这适用于 NaiveProxy、OlcRTC 和 ByeDPI。

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
| `startup-timeout` | `30` | 启动时的总检查预算（秒） |
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

### 😴 激活（休眠备用）

默认情况下 OlcRTC 作为**备用节点**：配置提前就绪，但进程处于休眠，直到主分组开始失败或用户手动选择 OlcRTC。

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
- 唤醒后客户端会立即检查 OlcRTC 本身。若没有任何包含分组选中它，且在 `sleep.idle` 内没有活动连接 —— 进程重新休眠。
- **手动选择会立即唤醒节点。**

> ℹ️ 现在**即使没有 `activation` 字段**也默认使用 `auto`。要完全恢复旧行为，请显式设置 `activation: always`。

> 💡 对 `wbstream` 推荐 `vp8channel`：该提供者的访客模式不授予发布数据通道的权限。可选的 `vp8.fps` 和 `vp8.batch_size` 默认为 `30` 和 `64`。

若设置了 `profiles`，顶层公共字段会被每个备用 profile 继承，FlClashM 会在启动前校验每个 profile 的最终配置。本地地址、SOCKS5 端口、CNC 模式和数据目录由客户端分配 —— 不能在配置里覆盖。

> ⚠️ 必填字段的错误在配置校验阶段即可发现。若 OlcRTC 进程稍后退出，客户端会显示**退出码和输出的最后几行**，而不是干等端口超时。

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

## 🚧 限制

- 内置节点只能写在 `proxies` 段。
- 本地地址和端口由客户端管理。
- 配置不能设置本地 `listen`；NaiveProxy 的 `server` 和 `port` 仅描述远端服务器。
- UDP：`byedpi` —— 启用（可用 `udp: false` 关闭）；`naiveproxy` 和 `olcrtc` **不**支持 UDP。

---

> 📎 节点生命周期的技术细节见[运行时](../development/runtime.md)。安全保证见[安全策略](../development/security.md)。
>
> 🌍 其他语言：[Русский](../../../ru/docs/user-guide/profiles.md) · [English](../../../en/docs/user-guide/profiles.md) · [فارسی](../../../fa/docs/user-guide/profiles.md)
