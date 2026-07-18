# FlClashM

[![下载量](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![最新版本](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![许可证](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)
[![基于 FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

> 基于 `mihomo` 的 Android 客户端，[FlClashX](https://github.com/pluralplay/FlClashX) 的分支，将复杂的审查规避工具隐藏在一个按钮之后。

[Русская версия](../../README.md) | [English version](../en/README.md) | [نسخه فارسی](../fa/README.md)

---

## 为什么需要这个客户端

有几个强大的审查规避工具，但它们各自独立运行：

- **[ByeDPI](https://github.com/hufrea/byedpi)** — 通过数据包操作绕过 DPI。
- **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — 基于 WebRTC 的加密隧道，伪装为视频通话。
- **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — 通过 Chromium 网络栈进行流量模仿。

我厌倦了从十几个不同的应用中拼凑出一个可用的解决方案：一个用于 VPN，一个用于绕过 DPI，一个用于流量伪装。没有一个能让我在一个地方配置所有东西，然后只需点击"连接"。

所以我创建了 **FlClashM**。它的目标是成为那个**一键解决方案**：提供商准备配置，用户按下开关，连接就能在任何网络中工作。

> ⚠️ 项目正在积极开发中。某些功能仍在完善，界面可能会变化。

---

## 主要优势

### 配置文件中直接定义内置节点

与普通客户端不同，FlClashM 可以**直接从 YAML 配置文件启动特殊节点**。它们看起来像普通代理，并参与路由规则：一个网站可以通过 ByeDPI 路由，另一个通过 OlcRTC，其他所有流量直连。

**[ByeDPI](https://github.com/hufrea/byedpi)** — 通过数据包操作绕过 DPI。FlClashM 自动从 ByeByeDPI 列表中循环尝试策略并缓存有效的策略。UDP 默认启用，可为单个节点设置 `udp: false` 将其关闭。

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-test:
      urls:
        - "https://example.com/"
```

**[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — 基于 WebRTC 的加密 TCP 隧道，伪装为通过 Jitsi Meet 或 Yandex Telemost 的视频通话。可以通过提供商的白名单。

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

**[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — 通过 Chromium 网络栈进行流量模仿。对 TLS 指纹识别和主动探测具有抵抗力。

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

[了解更多关于内置节点的信息](docs/user-guide/profiles.md)

### 通过配置文件实现分流

提供商可以直接在配置文件中指定哪些应用应该使用 VPN，哪些不应该。支持精确的包名、通配符和正则表达式。

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
  exclude-package:
    - '*.yandex.*'
    - '!ru.yandex.browser'
```

可以从文件或 URL 加载列表。配置文件设置优先于手动设置。

[了解更多关于分流的信息](docs/user-guide/split-tunneling.md)

---

## 其他功能

- 通过 `mihomo` 的 **VPN/TUN 连接**。
- 从链接、文件、二维码和 Android TV 导入**配置文件**。
- **工作模式**：规则、全局、直连。
- **小部件**和**快速设置磁贴**用于 VPN 控制。
- 带校验和验证的**内置更新**。
- 订阅到期的**通知**。
- 设备重启后的**自动启动**。
- 通过提供商提示进行**自定义**。

---

## 下载

发布版本在 [GitHub Releases](https://github.com/makriq-org/FlClashM/releases) 发布。

| 文件 | 描述 |
|------|------|
| `FlClashM-android-universal.apk` | 通用版本 |
| `FlClashM-android-arm64-v8a.apk` | 64 位 ARM |
| `FlClashM-android-armeabi-v7a.apk` | 32 位 ARM |
| `FlClashM-android-x86_64.apk` | x86_64 |
| `FlClashM-android-release.aab` | Android App Bundle |

默认情况下，内置更新器只显示稳定版本。可以在设置中启用预发布版本。

---

## 文档

### 用户
- **[内置节点](docs/user-guide/profiles.md)** — ByeDPI、OlcRTC、NaiveProxy
- **[分流](docs/user-guide/split-tunneling.md)** — 通过配置文件管理
- **[提供商提示](docs/user-guide/provider-hints.md)** — 自定义和行为

### 开发者
- **[架构](docs/development/architecture.md)** — 层级和服务
- **[运行时](docs/development/runtime.md)** — 配置文件处理和内置节点
- **[安全](docs/development/security.md)** — 安全策略
- **[发布](docs/development/release-contract.md)** — 版本发布和回滚
- **[上游同步](docs/development/upstream-sync.md)** — 基础更新
- **[构建验证](docs/development/verification.md)** — 本地和 CI 检查

---

## 构建

需要 Flutter 3.41.x、JDK 17、Android SDK/NDK 和 Go 1.26.x。

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

---

## 致谢

FlClashM 基于 [FlClashX](https://github.com/pluralplay/FlClashX) 构建——一个优秀的 Clash/Mihomo 跨平台客户端。非常感谢作者的工作和开源代码，没有它这个项目将不可能实现。

特别感谢 [ByeDPI](https://github.com/hufrea/byedpi)、[OlcRTC](https://github.com/openlibrecommunity/olcrtc) 和 [NaiveProxy](https://github.com/klzgrad/naiveproxy) 的作者——没有他们的工具，审查规避将不可能实现。

---

## 许可证

应用代码基于 GPL-3.0 许可证分发。第三方核心和捆绑的可执行文件保留其原始许可证。
