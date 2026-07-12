# 架构

FlClashM 基于 FlClashX 构建。产品逻辑与基础代码分离，以便更新不会破坏自定义功能。

## 主流程

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| 阶段 | 描述 |
|------|------|
| **RawProfile** | 原始配置文件 |
| **ProfileCompiler** | 读取配置文件并构建运行配置 |
| **SecurityPolicy** | 应用 Android 安全规则 |
| **RuntimePlan** | 构建运行时启动计划 |
| **EngineManager** | 管理引擎生命周期 |
| **EngineAdapter** | 到 `mihomo` 的桥接 |

## 层级

1. **FlClashX 基础** — UI、导航、基础运行时路径。
2. **产品层** (`lib/product/**`) — 配置文件编译、安全、更新。
3. **运行时层** — `mihomo`、内置节点。
4. **平台层** — Android VPN、服务、通知。

## 基础与产品边界

`lib/product/**` 之外的基础代码只能通过 `tool/product_touchpoints.json` 中的集成点访问产品层。

```bash
dart tool/check_product_boundaries.dart
```

## 核心服务

| 服务 | 负责 |
|------|------|
| `ProfileCompiler` | 读取和规范化配置文件 |
| `SecurityPolicy` | 强制安全规则 |
| `EngineManager` | 引擎生命周期 |
| `AppUpdateService` | 检查和安装更新 |
| `AccessControlService` | Android VPN 启动和授权 |
