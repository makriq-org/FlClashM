# 🏗 架构

FlClashM 构建于 FlClashX 之上。分支的产品逻辑与基线分离，使上游更新不会破坏定制功能。

## 🔗 主流水线

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| 阶段 | 作用 |
|------|------|
| **RawProfile** | 原始配置 |
| **ProfileCompiler** | 读取配置、规范化分流、编译内置节点 |
| **SecurityPolicy** | 在 Android 上强制启用 TUN |
| **RuntimePlan** | 构建运行时启动方案 |
| **EngineManager** | 管理引擎生命周期 |
| **EngineAdapter** | 通往 `mihomo` 的桥 |

## 🧱 分层

1. 🎛 **FlClashX 基线** —— UI、导航、基础运行时路径。
2. 📦 **产品层**（`lib/product/**`）—— 配置编译、安全、更新、仅分支页面。
3. ⚙️ **运行时层** —— `mihomo`（基准）及内置节点 `naiveproxy`、`olcrtc`、`byedpi`。
4. 📱 **平台层** —— Android VPN、前台服务、安装器、通知。

## 🚧 base/product 边界

`lib/product/**` 之外的基线代码**只能通过** `tool/product_touchpoints.json` 中的集成点访问产品层。

- 活跃的 `lib/views/**` **不复制**进 `lib/product/**`：基线保留上游屏幕，仅带最小钩子。
- `lib/product/**` 中的 Widget 类与 `Widget` 工厂默认禁止；FlClashM 自有元素必须带原因显式登记进 `tool/product_touchpoints.json` 的 `allowedProductUi`。

由门禁强制执行：

```bash
dart tool/check_product_boundaries.dart
```

> 📎 这与上游更新的关系见[上游同步](upstream-sync.md)。贡献者规则见 [AGENTS.md](../../../../AGENTS.md)。

## 🧩 核心服务

| 服务 | 负责 |
|------|------|
| `ProfileCompiler` | 读取与规范化配置 |
| `SecurityPolicy` | 在 Android 上强制启用 TUN |
| `EngineManager` | 引擎生命周期 |
| `BuiltInProxySupervisor` | 内置节点生命周期 |
| `AppUpdateService` | 检查、下载、安装应用更新 |
| `AppUpdateManifestVerifier` | 验证更新清单的签名与契约 |
| `AccessControlService` | 分流 |

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/architecture.md) · [English](../../../en/docs/development/architecture.md) · [فارسی](../../../fa/docs/development/architecture.md)
