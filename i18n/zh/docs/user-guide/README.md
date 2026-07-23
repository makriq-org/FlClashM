# 🚀 用户指南

让 FlClashM 精确做到你想要的一切 —— 从首次连接到精细调整路由。

---

## ⏱ 快速开始

1. 📥 **安装应用** —— 从 [GitHub Releases](https://github.com/makriq-org/FlClashM/releases) 下载 APK（该选哪个版本见 [README](../../README.md#-下载)）。
2. ➕ **添加配置** —— 通过订阅链接、文件、二维码或 Android TV。
3. 🔌 **拨动开关** —— 应用启用 VPN/TUN 并拉起所需的内置节点。

其余取决于配置内容。下面是最常用到的三个主题。

---

## 📖 章节

### 🧩 [内置节点](profiles.md)

FlClashM 的招牌功能：**ByeDPI、OlcRTC 和 NaiveProxy 直接从 YAML 配置启动**，并表现得像普通代理。一个站点可以走 DPI 绕过，另一个伪装成视频通话，其余直连。

> 如果你想了解如何为内置节点填写 `proxies`，以及启动检查如何工作 —— 从这里开始。

### 🎯 [分流](split-tunneling.md)

控制**哪些应用使用 VPN**、哪些直连。规则可在设置中手动配置，也可写在配置里（此时优先）。支持精确包名、通配符和正则表达式。

### 🎨 [提供商提示](provider-hints.md)

提供商可在订阅请求头里发送一组 `flclashm-*` 提示 —— 更换主题、背景、小组件集合、显示服务名称。这属于**外观与便利**；提示不影响安全或路由。

---

> 🌍 其他语言：[Русский](../../../ru/docs/user-guide/README.md) · [English](../../../en/docs/user-guide/README.md) · [فارسی](../../../fa/docs/user-guide/README.md)
