# 提供商提示

提供商可以在订阅响应头中传递 `flclashm-*` 前缀的提示。它们会影响应用的外观和行为，但不会削弱安全性。

## 工作原理

订阅在响应体中返回 YAML 配置文件，在响应头中返回提示。FlClashM 在添加或更新配置文件时应用这些提示。

## 可用的响应头

### 外观

| 响应头 | 描述 |
|--------|------|
| `flclashm-background` | 背景图片 |
| `flclashm-hex` | 配色方案 |

### 主屏幕

| 响应头 | 描述 |
|--------|------|
| `flclashm-widgets` | 小组件顺序 |
| `flclashm-view` | 节点页面视图 |
| `flclashm-denywidgets` | 禁用主屏幕编辑 |

### 服务信息

| 响应头 | 描述 |
|--------|------|
| `flclashm-servicename` | 服务名称 |
| `flclashm-servicelogo` | 服务标志 |
| `flclashm-serverinfo` | 服务器信息 |

### 设置

| 响应头 | 描述 |
|--------|------|
| `flclashm-settings` | 自动启动和更新检查 |
| `flclashm-globalmode` | 模式选择可见性 |

### 行为

| 响应头 | 描述 |
|--------|------|
| `flclashm-custom` | 何时应用外观：`add` 或 `update` |

## 边界

- 提示仅供参考。
- 它们不能修改 Android 安全性或安全策略。
- 用户设置优先于提供商建议。
