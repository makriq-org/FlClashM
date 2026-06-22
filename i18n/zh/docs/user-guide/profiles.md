# 内置节点

内置节点直接在 YAML 配置文件中定义，其工作方式与普通代理相同。FlClashM 会自动启动所需进程并管理端口。

## ByeDPI

**类型：** `byedpi`

支持两种模式：

### 自动策略选择

客户端从 ByeByeDPI 列表中循环尝试策略，找到有效的策略并缓存。

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-list: byebyeedpi
    test:
      urls:
        - "https://example.com/"
      sni: "example.com"
      timeout: 5
      requests: 1
      concurrency: 4
      min-success-ratio: 1.0
    cache:
      ttl: 604800
      recheck-after: 86400
      failure-threshold: 2
```

**参数：**

| 参数 | 描述 |
|------|------|
| `strategy-list` | 策略列表名称 (`byebyeedpi`) |
| `test.urls` | 测试地址 |
| `test.sni` | 用于 `{sni}` 替换的主机名 |
| `test.timeout` | 单次测试超时时间（秒），默认 5 |
| `test.requests` | 每个策略的请求数，默认 1 |
| `test.concurrency` | 并行测试数，默认 4 |
| `test.min-success-ratio` | 最小成功率，默认 1.0 |
| `cache.ttl` | 缓存有效期（秒），默认 7 天 |
| `cache.recheck-after` | 重新检查间隔（秒），默认 1 天 |
| `cache.failure-threshold` | 缓存失效前的错误次数，默认 2 |

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
```

**参数：**

| 参数 | 描述 |
|------|------|
| `auth.provider` | 认证提供商 (`jitsi`, `telemost`) |
| `room.id` | 视频通话房间标识符 |
| `crypto.key` | 256 位加密密钥（十六进制） |
| `net.transport` | 传输方式 (`datachannel`, `vp8channel`) |

## NaiveProxy

**类型：** `naiveproxy`

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
- 所有内置节点仅支持 TCP（始终 `udp: false`）。
