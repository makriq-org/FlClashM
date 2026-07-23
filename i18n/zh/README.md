<div align="center">

<img src="../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="128" height="128">

# FlClashM

**在 Android 上突破封锁 —— 只需一个按钮。**

[![下载量](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![最新版本](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![许可证](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)
[![基于 FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

`mihomo` 的 Android 客户端，[FlClashX](https://github.com/pluralplay/FlClashX) 的分支，把复杂的翻墙工具藏在一个开关背后。

[Русский](../../README.md) · [English](../en/README.md) · **中文** · [فارسی](../fa/README.md)

</div>

---

> ⚠️ 项目正在积极开发中。部分功能仍在完善，界面可能变化。

## 📑 目录

- [为什么需要这个客户端](#-为什么需要这个客户端)
- [核心优势](#-核心优势)
- [还能做什么](#-还能做什么)
- [下载](#-下载)
- [文档](#-文档)
- [构建](#-构建)
- [致谢](#-致谢)
- [许可证](#-许可证)

---

## 🎯 为什么需要这个客户端

有几款强大的翻墙工具，但每一款都自成一体：

- 🛡 **[ByeDPI](https://github.com/hufrea/byedpi)** —— 通过数据包操纵绕过 DPI，访问被「从内部」封锁的资源（如 YouTube、Discord）。
- 📞 **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** —— 把流量伪装成允许服务（如 Yandex Telemost）的 WebRTC 通话，绕过白名单。
- 🎭 **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** —— 把流量伪装成 Chrome 浏览器流量，绕过黑名单。

每种技术各有所长，却没有一个地方能把它们统一起来。我希望在一个地方配置好一切，然后只按一下「连接」。

于是有了 **FlClashM**。它的目标就是成为那个**唯一的按钮**：提供商准备好配置，用户拨动开关，连接便在任何网络下工作。

---

## ✨ 核心优势

### 🧩 直接写在配置里的内置节点

与普通客户端不同，FlClashM 可以**直接从 YAML 配置启动特殊节点**。它们表现得像普通代理，并参与路由规则：一个站点走 ByeDPI，另一个走 OlcRTC，其余直连。

<table>
<tr><td>

🛡 **ByeDPI** —— 自动遍历 DPI 绕过策略并缓存可用的一条。

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

</td></tr>
<tr><td>

📞 **OlcRTC** —— 伪装成视频通话的 WebRTC 隧道。

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

</td></tr>
<tr><td>

🎭 **NaiveProxy** —— 伪装成 Chrome 流量。

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

</td></tr>
</table>

📖 [了解更多内置节点 →](docs/user-guide/profiles.md)

### 🎯 通过配置分流

提供商可以直接在配置里定义分流规则 —— 哪些应用走 VPN，哪些不走。支持精确包名、通配符和正则表达式；列表可从文件或 URL 加载。配置优先于手动设置。

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

📖 [了解更多分流 →](docs/user-guide/split-tunneling.md)

---

## 🛠 还能做什么

- 🔌 通过 `mihomo` 的 **VPN/TUN 连接**。
- 📥 **配置**来自链接、文件、二维码和 Android TV。
- 🔀 **运行模式**：规则、全局、直连。
- 🧰 用于控制 VPN 的**小组件**和**快捷设置磁贴**。
- ⬆️ 带签名与校验和验证的**内置更新**。
- 🔔 订阅到期**通知**。
- 🚀 设备重启后**自动启动**。
- 🎨 通过[提供商提示](docs/user-guide/provider-hints.md)进行**外观定制**。

---

## 📥 下载

发布版本发布在 [GitHub Releases](https://github.com/makriq-org/FlClashM/releases)。

| 文件 | 用途 |
|------|------|
| `FlClashM-android-universal.apk` | 通用版（拿不准就选它） |
| `FlClashM-android-arm64-v8a.apk` | 64 位 ARM（大多数现代手机） |
| `FlClashM-android-armeabi-v7a.apk` | 32 位 ARM（旧设备） |
| `FlClashM-android-x86_64.apk` | x86_64（模拟器、部分平板） |
| `FlClashM-android-release.aab` | Android App Bundle |

> ℹ️ 内置更新器默认只显示稳定版。预发布版可在设置中开启。

---

## 📚 文档

完整参考请见 **[文档中心](docs/README.md)**。

**🚀 面向用户**
- 🧩 [内置节点](docs/user-guide/profiles.md) —— ByeDPI、OlcRTC、NaiveProxy
- 🎯 [分流](docs/user-guide/split-tunneling.md) —— 通过配置管理
- 🎨 [提供商提示](docs/user-guide/provider-hints.md) —— 外观与行为

**🛠 面向开发者**
- 🏗 [架构](docs/development/architecture.md) · ⚙️ [运行时](docs/development/runtime.md) · 🔒 [安全](docs/development/security.md)
- 📦 [发布](docs/development/release-contract.md) · 🔄 [上游同步](docs/development/upstream-sync.md) · ✅ [构建验证](docs/development/verification.md)

---

## 🏗 构建

需要 **Flutter 3.41.x**、**JDK 17**、**Android SDK/NDK** 和 **Go 1.26.x**。

### 在 NixOS 上（推荐）

所有依赖及其版本都由 `flake.nix` 固定。arm64 调试包一条命令即可构建：

```bash
nix develop -c make dev
```

结果：`build/app/outputs/flutter-apk/app-debug.apk`。

其余任务同理：

```bash
nix develop -c make fetch-upstream check
nix develop -c make install-dev
nix develop -c make release
nix develop -c make clean
```

> 另有 `test`、`analyze`、`boundaries`、`release-contract` 和 `drift` 目标。

### 不使用 Nix

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

📖 详见[构建验证](docs/development/verification.md)。

---

## 🙏 致谢

FlClashM 构建于 [FlClashX](https://github.com/pluralplay/FlClashX) 之上 —— 一款出色的 Clash/Mihomo 跨平台客户端。非常感谢作者们的工作与开源代码，没有它们本项目无从谈起。

特别感谢 [ByeDPI](https://github.com/hufrea/byedpi)、[OlcRTC](https://github.com/openlibrecommunity/olcrtc) 和 [NaiveProxy](https://github.com/klzgrad/naiveproxy) 的作者 —— 没有他们的工具，翻墙将无从实现。

---

## 📄 许可证

应用代码以 **GPL-3.0** 许可证分发。第三方内核与内置可执行文件保留其原始许可证。
