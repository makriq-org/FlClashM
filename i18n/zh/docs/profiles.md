# 🧩 配置指南

[← README](../README.md) · [Русский](../../ru/docs/profiles.md) · [English](../../en/docs/profiles.md) · **中文** · [فارسی](../../fa/docs/profiles.md)

已有订阅只需导入应用。本指南供编辑 YAML 或为他人提供订阅时查阅。

[节点](#nodes) · [休眠备用](#activation) · [检测](#checks) · [应用分流](#apps) · [订阅响应头](#headers)

## 配置构建器与编辑器

可以直接在应用中使用节点、策略组和规则创建配置，无需提供 YAML 文件。配置页面提供共享资源和脚本；本地规则列表可导入、预览和编辑。MRS 支持文本预览，并保留原始数据。

导入的配置支持 YAML 编辑、覆写和最终配置预览。脚本预览不会改变正在运行的连接。后台服务负责保存更改，关闭界面不会中断连接或订阅更新。

升级前请保存备份。保存新的配置或资源后，旧版本应用可能无法打开更新后的存储。降级需要使用旧版本创建的备份，其中不包含之后的更改。

## 🚀 最小配置

```yaml
proxies:
  - name: dpi-auto
    type: byedpi
proxy-groups:
  - name: main
    type: select
    proxies: [dpi-auto, DIRECT]
rules:
  - MATCH,main
```

内置节点放在 `proxies` 中，与普通 mihomo 分组和规则一起使用。本地地址、端口和文件由应用分配；NaiveProxy 的远端 `server` 和 `port` 由配置指定。

<a id="nodes"></a>

## 🔌 内置节点

仅 ByeDPI 支持 UDP，默认开启，可用 `udp: false` 关闭。NaiveProxy、OlcRTC 和 StormDNS 不支持 UDP。

### NaiveProxy

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

必填：`name`、`type`、`server`、`port`、`username`、`password`。`transport` 默认为 `https`，也可用 `quic`。可选：`insecure-concurrency`（1–4）、`tunnel-timeout`、`idle-timeout`、`post-quantum`、`headers`、`host-resolver-rules`。旧字段 `proxy`、本地 `listen`、诊断文件、代理链和未知字段均被拒绝。

### ByeDPI

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    strategies:
      - builtin:byebyeedpi
      - "--disorder 1"
      - "https://example.org/byedpi-strategies.txt"
```

`mode: auto` 尝试策略并按物理网络缓存结果（最多 16 个网络，无需访问 SSID）。启动预算耗尽后使用备用策略，并在后台继续选择。缓存会标记结果已验证还是临时结果；备用策略使用自己的 `retry-after`。`mode: manual` 使用 `strategy`；省略 `mode` 时，有 `strategy` 就采用 manual，否则采用 auto。

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    strategy: "--disorder 1 --auto=torst --tlsrec 1+s"
```

HTTPS 列表每行一个策略；空行和以 `#` 开头的行被忽略。支持 `{sni}`。下载限制与下文的解析器列表相同。`strategy-test` 仅用于策略选择，不替代 `connectivity-check`；旧字段 `test` 不再支持。

<details>
<summary>自动选择参数</summary>

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `strategies` | `[builtin:byebyeedpi]` | 按顺序组合内置集、内联策略和公开 HTTPS 列表 |
| `strategy-test.urls` | 内置 YouTube 端点 | 用于选择的地址 |
| `strategy-test.sni` | `google.com` | 替换 `{sni}` 的主机名 |
| `strategy-test.dns-resolver` | `https://1.1.1.1/dns-query` | 测试地址的 DoH 解析器；`system` 使用系统解析器 |
| `strategy-test.timeout` | `5s` | 单次检查超时 |
| `strategy-test.requests` | `1` | 每条策略的请求数 |
| `strategy-test.request-concurrency` | `4` | 单个候选内的并行 HTTP 请求数 |
| `strategy-test.min-success-ratio` | `1.0` | 成功请求的最小比例 |
| `strategy-selection.strategy-concurrency` | `4` | 同时检查的策略数 |
| `strategy-selection.startup-timeout` | `0s` | 节点启动前的选择预算 |
| `strategy-selection.continue-in-background` | `true` | fallback 后是否在后台继续检查列表 |
| `strategy-selection.fallback-strategy` | 内置策略 | 选择未及时完成时使用的临时策略 |
| `strategy-selection.retry-after` | `5m` | fallback 后再次选择前的暂停 |
| `strategy-selection.cache.ttl` | `7d` | 缓存生存期 |
| `strategy-selection.cache.recheck-after` | `1d` | 重新检查间隔 |
| `strategy-selection.cache.failure-threshold` | `2` | 重置缓存前的错误次数 |

使用 `0s` 时，节点会立即以缓存或备用策略启动，并在后台继续选择。禁用后台选择时，默认预算为 `15s`。

</details>

<a id="olcrtc"></a>

### OlcRTC

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    provider: jitsi
    room: "https://meet.example.org/room"
    encryption-key: "<64-hex-key>"
    transport: datachannel
    dns-server: "1.1.1.1:53"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

仅支持 CNC 客户端模式。请将 `<64-hex-key>` 替换为服务器密钥，必须是 64 个十六进制字符。`provider: none` 必须提供 `engine`、`engine-url`、`engine-token`，其他提供商禁止使用这些字段。禁止 `profiles`、`failover`、`video.hw`、本地监听和文件密钥。

`dns-server: system` 使用 Android 物理网络的第一个 DNS：IPv4 为 `host:53`，IPv6 为 `[IPv6]:53`。该地址变化时重启依赖它的活动节点。若 DNS 不可用，启动立即报错 `physical DNS is unavailable`。应用计划时的启动失败会中止应用；后台唤醒失败后按 `retry-after` 等待。客户端和服务器必须支持 OLC2 和 OLVC 5。

内置运行时来自 [Ghostlane 分支](https://github.com/ghostlane-project/olcrtc)。
新服务请使用以下组合：

| `provider` | `transport` | `room` | 其他要求 |
|---|---|---|---|
| `vkcalls` | `vp8channel` 或 `videochannel` | `https://vk.ru/call/join/<id>` | VK 通话加入链接；禁止非空 `provider-token` |
| `mtslink` | `vp8channel` | `https://my.mts-link.ru/j/<owner>/<event>` | MTS Link 永久会议 |
| `salutejazz` | `datachannel` | `<code>:<password>` | SaluteJazz 房间代码和密码 |
| `max` | `datachannel` | `https://max.ru/joincall/<hash>` | 必须提供 `provider-token`：MAX calls session key 或 calls token |

令牌只通过私有配置传给 OlcRTC 进程；请勿公开包含令牌的配置。
不支持的服务与传输组合会在进程启动前被拒绝。

<details>
<summary>OlcRTC 字段与传输</summary>

| 参数 | 说明 |
|------|------|
| `provider` | 连接提供者：`jitsi`、`telemost`、`wbstream`、`salutejazz`、`vkcalls`、`mtslink`、`max`、`none` |
| `room` | 房间 URL 或 ID；除 `provider: none` 外必填 |
| `encryption-key` | 256 位加密密钥 —— **恰好 64 个十六进制字符** |
| `transport` | 传输：`datachannel`、`vp8channel`、`seichannel`、`videochannel` |
| `dns-server` | 必填：`host:port` 或 `system` |
| `transport-options` | 当前传输的可选参数；`datachannel` 禁止此段 |

`datachannel` 禁止 `transport-options`。`vp8channel` 默认 `fps: 30`、`batch-size: 64`；`seichannel` 另有 `fragment-size: 900`、`ack-timeout: 2s`。`videochannel` 支持 `codec`（`qrcode`/`tile`）、`width`、`height`、`fps`、`fragment-size`、`qr-recovery`、`tile-module`、`tile-rs`。默认 `qrcode`、1920×1080、`qr-recovery: low`；tile 为 1080×1080。旧字段 `bitrate` 可接受但被忽略。

```yaml
proxies:
- name: rtc
  type: olcrtc
  provider: jitsi
  room: https://meet.example.org/room
  encryption-key: "<64-hex-key>"
  transport: seichannel
  dns-server: 1.1.1.1:53
  transport-options:
    fps: 30
    batch-size: 64
    fragment-size: 900
    ack-timeout: 2s
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - rtc
```

</details>

### StormDNS

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

`domains`、`encryption`、`encryption-key` 必填，无默认值，必须与服务器一致。`none` 和 `xor` 无法向解析器运营者隐藏内容。首次启动会扫描解析器，最长可达两分钟。

<details>
<summary>解析器与缓存</summary>

| 字段 | 说明 |
|------|------|
| `domains` | 委派给 StormDNS 服务端的域名 |
| `encryption` | `none`、`xor`、`chacha20`、`aes-128-gcm`、`aes-192-gcm`、`aes-256-gcm` |
| `encryption-key` | 共享密钥；必须与服务端一致 |

`resolvers` 为空或省略时使用 `[system]`。按顺序展开来源；按 IP 去重，保留首次出现的端口。结果为空则拒绝。配置中的 CIDR 最多允许 65536 个地址。

| 条目 | 添加内容 |
|------|---------|
| `system` | 物理网络（非 VPN）的 DNS |
| `8.8.8.8` | 一个使用 53 端口的解析器 |
| `1.1.1.1:5353` | 一个使用自定端口的解析器 |
| `192.168.1.0/30` | CIDR 最多 65536 个地址。IPv4 超过 2 个地址时去除首尾；`/31` 和 `/32` 全部保留。IPv6 超过 2 个地址时去除首地址 |
| `https://…` | 来自远程列表的解析器 |

每个配置最多 32 个 HTTPS 列表，下载 URL 不得包含凭据、片段或本地服务器地址；列表内部可含私有 IP/CIDR。响应限制：1 MiB、15 秒，禁止重定向。失败时即使超过 `refresh` 也使用旧缓存；没有缓存则跳过该来源。应用配置时检查 `refresh`。

| `resolver-policy` | 默认值 | 说明 |
|-------------------|--------|------|
| `refresh` | `24h` | 远程列表的刷新周期 |
| `strategy` | `least-loss` | `random`、`round-robin`、`least-loss`、`lowest-latency` |
| `auto-disable` | `true` | 停用不再应答的解析器 |
| `recheck` | `true` | 定期重测已停用的解析器 |

| `startup.mode` | 作用 |
|----------------|------|
| `scan` | 完整扫描解析器（启动最慢） |
| `cached`（默认） | 从缓存启动，不重测 MTU |
| `verified` | 从缓存启动并重测 MTU |

缓存关联解析器、`domains` 和 StormDNS 版本。`startup.max-age` 是整天倍数的时长字符串，范围 `0s` 至 `365d`（默认 `30d`，也可用 `720h`，但不能用数字 `30`）。无合适缓存时重新扫描。系统 DNS 变化会清除 MTU 缓存并重启依赖它的活动节点，无需 UI。配置禁止本地 DNS/SOCKS、解析器文件、日志路径及 `startup.mode: ask`。

</details>

<details>
<summary>预设与细调</summary>

顺序：默认值 → `preset` → 显式字段。时长使用带单位的字符串（`600ms`、`30s`、`24h`、`30d`）。越界值会在启动前被拒绝。

| `preset` | 复制次数（upload / download / upload-setup / download-setup） | 压缩 |
|----------|--------------------------------------------------------------|------|
| `messenger`（默认） | 1 / 7 / 3 / 8 | `lz4` |
| `balanced` | 2 / 5 / 3 / 6 | `lz4` |
| `bulk` | 3 / 3 / 4 / 4 | `zstd` |

```yaml
proxies:
- name: storm
  type: stormdns
  domains:
  - v.example.com
  encryption: chacha20
  encryption-key: "<key>"
  preset: bulk
  duplication:
    upload: 2
  compression:
    upload: zlib
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - storm
```

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

配置字段通过 `core/backend/compile/storm_schema.json` 映射至原生键，例如 `arq.window` → `ARQ_WINDOW_SIZE`。

</details>

<a id="activation"></a>

## 😴 休眠备用

OlcRTC 和 StormDNS 默认 `activation: auto`：手动选择或受监测分组故障时启动。节点必须直接属于分组。未被选择且无连接时，经过 `sleep.idle` 后休眠；`0s` 表示在 VPN 重启前不休眠。设为 `activation: always` 可随配置启动。

`activation` 和 `connectivity-check` 必须放在 `proxies` 的具体节点内。`activation: auto` 需要直接包含节点的分组及唤醒 URL（显式指定或从节点检测、分组、应用设置继承），否则拒绝配置。这两个区块的时长必须是整秒（`1s`、`1m`），不允许 `500ms`。

```yaml
proxies:
- name: rtc
  type: olcrtc
  provider: jitsi
  room: https://meet.example.org/room
  encryption-key: "<64-hex-key>"
  transport: datachannel
  dns-server: 1.1.1.1:53
  activation:
    mode: auto
    wake:
      urls:
      - https://example.org/generate_204
      interval: 30s
      failures: 2
      retry-after: 5m
    sleep:
      idle: 15m
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - rtc
```

<details>
<summary>唤醒与休眠参数</summary>

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `mode` | `auto` | `auto` 让备用节点休眠；`always` 为旧的常驻启动 |
| `wake.urls` | `connectivity-check` 链 | 用于探测被观察分组的公网 HTTP(S) 地址 |
| `wake.interval` | `30s` | 休眠期间的探测间隔 |
| `wake.failures` | `2` | 唤醒前连续失败的轮数 |
| `wake.retry-after` | `5m` | 启动失败后的暂停 |
| `sleep.idle` | `15m` | 无连接与无选择直至休眠的时长；`0s` 表示 VPN 重启前不休眠 |

</details>

<a id="checks"></a>

## 🩺 连通性检测

始终检测进程和 SOCKS 端口。HTTP(S) 地址依次取自节点的 `connectivity-check.urls`、最近的分组或应用全局测试 URL。`required: false` 在后台检测；`true` 要求有 URL，失败时回滚启动。任何有效 HTTP 响应（包括 4xx/5xx）均视为成功。

```yaml
proxies:
- name: naive
  type: naiveproxy
  server: example.com
  port: 443
  username: user
  password: pass
  connectivity-check:
    urls:
    - https://example.org/generate_204
    required: true
```

仅允许无凭据或片段的公共 HTTP(S) URL。请求前检查 DNS；连接通过受测节点的 SOCKS，不会直接连接回退。TLS 验证原始主机名。

<details>
<summary>完整检测参数</summary>

| 字段 | 默认值 | 含义 |
|------|--------|------|
| `urls` | — | 最多 16 个要检查的地址（公网 HTTP(S)，不含凭据或片段） |
| `required` | `false` | 该检查是否为启动所必需 |
| `timeout` | `5s` | 单次请求超时 |
| `startup-timeout` | `30s`（`stormdns` 为 `2m`） | 启动时的总检查预算 |
| `retry-interval` | `1s` | 重试间隔 |
| `requests` | `1` | 请求次数 |
| `concurrency` | `1` | 并行请求数 |
| `min-success-ratio` | — | 成功响应的最小比例（不设则一次成功即可） |

</details>

<a id="apps"></a>

## 🎯 哪些应用走 VPN

配置规则优先于手动设置。`include-package` 仅让列出的应用走 VPN，`exclude-package` 让其余应用走 VPN。请选择一种模式。若原始 `include-package: []` 或 `exclude-package: []` 为空且无其他来源，不创建配置规则，使用通用设置。

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

| 格式 | 示例 | 含义 |
|------|------|------|
| 🎯 精确名 | `com.termux` | 精确匹配包名 |
| ✳️ 通配符 | `*.yandex.*` | 所有 Yandex 应用 |
| 🔤 正则 | `re:^org\.mozilla\..+$` | 所有 Mozilla 应用 |
| 🚫 排除 | `!ru.yandex.browser` | 从列表中移除 |

`include-package-url` / `exclude-package-url` 接受 HTTP(S) 列表，每行一个包名或选择器。离线时使用旧缓存；订阅和应用列表可以使用私有服务器。Android 忽略本地 `include-package-file` / `exclude-package-file` 并记录日志。

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

VPN 运行时，界面显示最近一次成功建立隧道时的规则。仅重新加载 mihomo 不会改变它们。若快照不可用，界面会明确显示配置声明，而非已确认状态。

<a id="headers"></a>

## 🎨 订阅响应头

订阅 HTTP 响应正文包含 YAML，响应头提供提示。支持 `flclashm-*` 和兼容的 `flclashx-*`，前者优先。布尔值为 `true`/`false`。

```text
flclashm-custom: update
flclashm-hex: 5c6bc0:vibrant:pureblack
flclashm-view: type:tab;sort:delay;card:min
flclashm-settings: autostart,autoupdate
```

`flclashm-custom: add` 在添加时应用 `hex`、`view`、`widgets` 和 `settings`，`update` 在每次更新时应用；其他响应头不受它控制。关闭 `overrideProviderSettings` 时才应用 `flclashm-settings`：列出的标志开启，未列出的重置为 `false`。`androidsecure` 仅关闭 mixed-port，不改变 VPN 选择。`GLOBAL` 支持 `flclashm-override` / `flclashx-override`，前者优先。

<details>
<summary>响应头与格式参考</summary>

| 响应头 | 值 | 用途 |
|---|---|---|
| `flclashm-newdomain` / `flclashx-newdomain` | 主机名 | 保存订阅 URL 的新主机；协议、端口和路径保持不变 |
| `flclashm-background` | `URL[,opacity]` | 背景；可选图片可见度 1–100 |
| `flclashm-hex` | `HEX[:variant][:pureblack]` | 配色主题 |
| `flclashm-widgets` | `list` | 小组件顺序 |
| `flclashm-view` | `key:value;…` | 节点页面布局 |
| `flclashm-newboard` | `true/false` | 新仪表盘 |
| `flclashm-denywidgets` | `true/false` | 禁止编辑仪表盘 |
| `flclashm-servicename` | `base64` | 服务名称 |
| `flclashm-servicelogo` | `base64(URL)` | 服务图标 |
| `flclashm-serverinfo` | `base64` | 服务器信息分组名 |
| `flclashm-buyplan` | `URL` | 续订 |
| `flclashm-buytraffic` | `URL` | 购买流量 |
| `flclashm-settings` | `autostart,autoupdate,…` | 逗号分隔的设置 |
| `flclashm-globalmode` | `false` | 隐藏全局模式选择 |
| `flclashm-androidsecure` | `true` | 在 Android 关闭 mixed-port |
| `flclashm-custom` | `add/update` | 何时应用外观 |
| `announce` | `text/base64:…` | 公告 |
| `support-url` | `URL` | 支持 |
| `profile-update-interval` | 整数小时 | 订阅自动更新间隔，须为正数 |
| `x-hwid-max-devices-reached` | `true` | 已达设备上限 |
| `x-hwid-not-supported` | `true` | 不支持 HWID |

`flclashm-hex`：6/8 位十六进制颜色，可带 `#`，后接 Material 3 方案和 `pureblack`。方案：`tonalSpot`、`fidelity`、`monochrome`、`neutral`、`vibrant`、`expressive`、`content`、`rainbow`、`fruitSalad`。

`flclashm-view` 键值对以 `;` 分隔，所有键可选：

| 键 | 允许的值 |
|----|----------|
| `type` | `list`、`tab` |
| `sort` | `none`、`delay`、`name` |
| `layout` | `loose`、`standard`、`tight` |
| `icon` | `icon`（或 `standard`）、`none` |
| `card` | `expand`、`shrink`、`min`、`oneline` |

`flclashm-settings` 标志：

| 标志 | 启用内容 |
|------|----------|
| `autostart` | 打开应用时自动连接（`ui.attach`） |
| `autoupdate` | 自动检查更新 |
| `autorun` | 系统启动时启动应用 *(桌面)* |
| `shadowstart` | 静默（后台）启动 |
| `minimize` | 退出时最小化到托盘 *(桌面)* |

</details>
