# 内置节点

内置节点直接在 YAML 配置文件中定义，其工作方式与普通代理相同。FlClashM 会自动启动所需进程并管理端口。

## ByeDPI

**类型：** `byedpi`

UDP 默认启用。可在节点中设置 `udp: false` 将其关闭。

支持两种模式：

### 自动策略选择

客户端从 ByeByeDPI 列表中循环尝试策略，找到有效的策略并缓存。

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

**参数：**

| 参数 | 描述 |
|------|------|
| `strategy-list` | 策略列表名称，默认 `byebyeedpi` |
| `strategies` | 替代 `strategy-list` 的自定义有序策略列表 |
| `strategy-test.urls` | 策略测试地址；默认使用内置 YouTube 测试端点 |
| `strategy-test.sni` | 用于 `{sni}` 替换的主机名 |
| `strategy-test.timeout` | 单次测试超时时间（秒），默认 5 |
| `strategy-test.requests` | 每个策略的请求数，默认 1 |
| `strategy-test.concurrency` | 一个策略内的并行 HTTP 请求数，默认 4 |
| `strategy-test.min-success-ratio` | 最小成功率，默认 1.0 |
| `selection.concurrency` | 同时检查的策略数，默认 4 |
| `selection.foreground-timeout` | 启动节点前的总时间预算（秒），默认 15 |
| `selection.background` | 启动备用策略后继续后台检查，默认 `true` |
| `fallback-args` | 前台选择超时后使用的临时策略参数 |
| `cache.ttl` | 缓存有效期（秒），默认 7 天 |
| `cache.recheck-after` | 重新检查间隔（秒），默认 1 天 |
| `cache.retry-after` | 临时备用策略后的重试间隔，默认 5 分钟 |
| `cache.failure-threshold` | 缓存失效前的错误次数，默认 2 |

候选策略会以受限并行批次进行检查。前台时间预算用尽后，ByeDPI
立即使用备用策略启动，并在后台继续检查剩余列表。服务器返回的任何有效
HTTP 响应（包括 `4xx` 和 `5xx`）都视为成功；临时备用策略不会被当作已验证结果。

未指定 `mode` 时，包含 `args` 的节点使用手动模式，否则使用自动模式。
`strategy-test.urls` 可覆盖内置测试端点。

如果没有策略可用，将使用备用策略。

### 手动策略

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

## OlcRTC

**类型：** `olcrtc`

不支持 UDP；只允许设置 `udp: false`。

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
```

**参数：**

| 参数 | 描述 |
|------|------|
| `auth.provider` | 认证提供商 (`jitsi`, `telemost`, `wbstream`, `none`) |
| `room.id` | 视频通话房间标识符 |
| `crypto.key` | 256 位加密密钥（十六进制） |
| `net.transport` | 传输方式 (`datachannel`, `vp8channel`, `seichannel`, `videochannel`) |
| `net.dns` | 必填 DNS 服务器，格式为 `host:port` |

## NaiveProxy

**类型：** `naiveproxy`

不支持 UDP；只允许设置 `udp: false`。

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

## 限制

- 内置节点只能在 `proxies` 部分定义。
- 客户端自动管理本地地址和端口。
- 配置文件不能设置 `listen`、`server`、`port`、`ip`。
- ByeDPI 默认使用 UDP，可通过 `udp: false` 关闭。NaiveProxy 和 OlcRTC
  不支持 UDP。
