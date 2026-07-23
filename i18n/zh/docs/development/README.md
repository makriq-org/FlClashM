# 🛠 开发者文档

FlClashM 如何构建，以及如何在不破坏低成本上游同步的前提下与之协作。

**核心原则：** 分支的产品逻辑位于 `lib/product/**`，与 FlClashX 基线分离。基线代码只通过登记过的集成点访问它。这让上游更新保持低成本，也避免分支特性溶解进基线。

---

## 📖 章节

| 章节 | 内容 |
|------|------|
| 🏗 **[架构](architecture.md)** | 主处理流水线、分层、base/product 边界、核心服务 |
| ⚙️ **[运行时](runtime.md)** | 配置处理、内置节点验证与生命周期、VPN 快照 |
| 🔒 **[安全](security.md)** | 运行时策略、Android 保护、提供商请求头边界 |
| 📦 **[发布](release-contract.md)** | 发布内容、流水线、签名更新分发、回滚 |
| 🔄 **[上游同步](upstream-sync.md)** | 低成本的基线更新流程 |
| ✅ **[构建验证](verification.md)** | 本地门禁与 CI |

---

## 🧰 本地命令（速览）

在 NixOS 上整个环境由 `flake.nix` 定义：

```bash
nix develop -c make dev              # 调试 APK（arm64）
nix develop -c make check            # boundaries + release-contract + drift + test + analyze
nix develop -c make fetch-upstream   # 拉取 upstream/dev
```

构建与检查细节见[构建验证](verification.md)和[项目 README](../../README.md#-构建)。

> 🤖 代码协作规则（base/product 边界、touchpoints、drift 预算）见 [AGENTS.md](../../../../AGENTS.md)。

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/README.md) · [English](../../../en/docs/development/README.md) · [فارسی](../../../fa/docs/development/README.md)
