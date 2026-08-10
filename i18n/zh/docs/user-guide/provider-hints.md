# 🎨 提供商提示

提供商可在订阅响应头里发送一组以 `flclashm-*` 为前缀的提示。它们调节应用的**外观与行为**，但**不能削弱安全**。

## 🔧 工作方式

订阅在响应体里返回 YAML 配置，在 HTTP 头里返回提示。FlClashM 在添加或更新配置时应用它们（见 [`flclashm-custom`](#-行为)）。

> [!NOTE]
> 部分请求头的值使用 **base64** 编码（下文有标注）。布尔型请求头接受 `true`/`false`。

---

## 🖌 外观

| 请求头 | 值 | 作用 |
|--------|----|------|
| `flclashm-background` | URL | 背景图片 |
| `flclashm-hex` | `HEX[:variant][:pureblack]` | 配色主题（见下） |

### `flclashm-hex` 格式

- **`HEX`** —— 颜色：6 或 8 个十六进制字符，可带或不带 `#`（`5c6bc0`、`#5c6bc0`）。8 位含 alpha 通道。
- **`variant`**（可选）—— Material 3 方案名：`tonalSpot`、`fidelity`、`monochrome`、`neutral`、`vibrant`、`expressive`、`content`、`rainbow`、`fruitSalad`。
- **`pureblack`**（可选）—— 纯黑背景（适合 OLED）。

```text
flclashm-hex: 5c6bc0                    # 仅颜色
flclashm-hex: #5c6bc0:vibrant           # 颜色 + 方案
flclashm-hex: 5c6bc0:vibrant:pureblack  # 颜色 + 方案 + 黑色背景
```

---

## 🏠 主屏幕

| 请求头 | 值 | 作用 |
|--------|----|------|
| `flclashm-widgets` | 列表 | 仪表盘小组件的顺序与集合 |
| `flclashm-view` | `键:值;…` | 节点页面布局（见下） |
| `flclashm-newboard` | `true`/`false` | 启用新仪表盘（「新外观」） |
| `flclashm-denywidgets` | `true`/`false` | 禁止编辑主屏幕 |

### `flclashm-view` 格式

以 `;` 分隔的 `键:值` 对。每个键都可选 —— 只设你需要的。

| 键 | 允许的值 |
|----|----------|
| `type` | `list`、`tab` |
| `sort` | `none`、`delay`、`name` |
| `layout` | `loose`、`standard`、`tight` |
| `icon` | `icon`（或 `standard`）、`none` |
| `card` | `expand`、`shrink`、`min`、`oneline` |

```text
flclashm-view: type:tab;sort:delay;card:min
```

---

## 🏷 服务信息

> [!IMPORTANT]
> 这三个请求头的值以 **base64** 传递。

| 请求头 | 值 | 作用 |
|--------|----|------|
| `flclashm-servicename` | base64 | 服务名称 |
| `flclashm-servicelogo` | base64（URL） | 服务图标 |
| `flclashm-serverinfo` | base64 | 含服务器信息的分组名 |

---

## ⚙️ 设置

| 请求头 | 值 | 作用 |
|--------|----|------|
| `flclashm-settings` | 逗号分隔的标志 | 预填应用设置 |
| `flclashm-globalmode` | `false` 隐藏 | 是否显示全局模式选择器（默认显示） |

### `flclashm-settings` 标志

| 标志 | 启用内容 |
|------|----------|
| `autostart` | 自动启动 / 自动连接（含重启后） |
| `autoupdate` | 自动检查更新 |
| `autorun` | 系统启动时启动应用 *(桌面)* |
| `shadowstart` | 静默（后台）启动 |
| `minimize` | 退出时最小化到托盘 *(桌面)* |

```text
flclashm-settings: autostart,autoupdate
```

> [!IMPORTANT]
> `flclashm-settings` **仅在用户未手动覆盖**提供商设置时生效。用户的手动选择始终优先。

---

## 🔁 行为

| 请求头 | 值 | 作用 |
|--------|----|------|
| `flclashm-custom` | `add` / `update` | 何时应用定制 |

- **`add`** —— 仅在**添加新**配置时。
- **`update`** —— 每次配置刷新时。
- 其他任何值（或缺省）—— 不应用定制。

---

## 📣 标准订阅请求头

除 `flclashm-*` 外，应用还识别常见的面板请求头：

| 请求头 | 作用 |
|--------|------|
| `announce` | 应用内公告（支持 `base64:` 前缀） |
| `support-url` | 支持链接 |
| `x-hwid-max-devices-reached` | 「设备数达上限」提示 |
| `x-hwid-not-supported` | 「不支持的 HWID」提示 |

---

## 🚧 边界

- 💡 提示为**建议性**。
- 🔒 它们**不能**更改 Android 保护或安全策略。
- 🏆 用户设置重于提供商建议。

---

> 📎 外观为何无法影响安全 —— 见[安全策略](../development/security.md#-提供商请求头)。
>
> 🌍 其他语言：[Русский](../../../ru/docs/user-guide/provider-hints.md) · [English](../../../en/docs/user-guide/provider-hints.md) · [فارسی](../../../fa/docs/user-guide/provider-hints.md)
