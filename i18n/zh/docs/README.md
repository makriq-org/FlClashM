# 📚 FlClashM 文档

欢迎阅读 **FlClashM** 的参考文档 —— 一款把多种翻墙工具藏在一个按钮背后的 `mihomo` Android 客户端。

文档分为两部分：**用户指南** —— 如果你在配置订阅、只希望它正常工作；以及**开发者部分** —— 如果你要构建应用、同步分支或深入了解其结构。

> 🌍 语言：[Русский](../../ru/docs/README.md)（基准） · [English](../../en/docs/README.md) · **中文** · [فارسی](../../fa/docs/README.md)
>
> 俄文版最先更新。译文可能略有滞后 —— 有疑问时以俄文为准。

---

## 🚀 用户指南

如何让应用做到你想要的。

| 章节 | 内容 |
|------|------|
| 🧩 **[内置节点](user-guide/profiles.md)** | 直接写在 YAML 配置里的 ByeDPI、OlcRTC 和 NaiveProxy |
| 🎯 **[分流](user-guide/split-tunneling.md)** | 哪些应用走 VPN，哪些绕过 |
| 🎨 **[提供商提示](user-guide/provider-hints.md)** | 用于外观与行为的 `flclashm-*` 请求头 |

👉 不知从何入手 —— 请看 **[用户指南概览](user-guide/README.md)**。

---

## 🛠 面向开发者

分支如何构建，以及如何与之协作。

| 章节 | 内容 |
|------|------|
| 🏗 **[架构](development/architecture.md)** | 分层、base/product 边界、核心服务 |
| ⚙️ **[运行时](development/runtime.md)** | 配置处理与内置节点生命周期 |
| 🔒 **[安全](development/security.md)** | 分支保证什么、提供商不能改什么 |
| 📦 **[发布](development/release-contract.md)** | 发布内容、签名、更新分发、回滚 |
| 🔄 **[上游同步](development/upstream-sync.md)** | 如何低成本更新上游基线 |
| ✅ **[构建验证](development/verification.md)** | 本地门禁与 CI |

👉 整体导览请看 **[开发者概览](development/README.md)**。

---

## 🧭 其他去处

- 📄 **[项目 README](../README.md)** —— 这是什么、为什么、如何下载。
- 📝 **[CHANGELOG](../../../CHANGELOG.md)** —— 按版本的变更历史。
- 🤖 **[AGENTS.md](../../../AGENTS.md)** —— 代码协作规则（面向贡献者与智能体）。
