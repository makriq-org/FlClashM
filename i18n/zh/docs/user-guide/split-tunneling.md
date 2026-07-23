# 🎯 分流

分流回答一个简单的问题：**哪些应用走 VPN，哪些直连**。有两种设置方式：

- 🖐 **手动** —— 在应用设置里；
- 📄 **通过配置** —— 提供商直接在 YAML 里定义规则。

> ℹ️ 配置里的规则**优先**于手动设置。若配置定义了分流，应用设置会显示访问控制由配置管理。

---

## 📄 通过配置设置

规则位于 `tun` 段，有两种互斥模式。

### ✅ 白名单 —— 只有选中的应用

**只有**列出的应用走 VPN，其余直连。

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

### ⛔ 黑名单 —— 排除选中的应用

**除列出的应用之外**都走 VPN。

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

> ⚠️ `include-package` 与 `exclude-package` **不能**同时使用。

---

## 🧬 选择器格式

除精确包名外，还支持通配符和正则表达式：

| 格式 | 示例 | 含义 |
|------|------|------|
| 🎯 精确名 | `com.termux` | 精确匹配包名 |
| ✳️ 通配符 | `*.yandex.*` | 所有 Yandex 应用 |
| 🔤 正则 | `re:^org\.mozilla\..+$` | 所有 Mozilla 应用 |
| 🚫 排除 | `!ru.yandex.browser` | 从列表中移除 |

它们可以组合 —— 例如「除浏览器外的全部 Yandex，加上全部 Mozilla」：

```yaml
tun:
  enable: true
  exclude-package:
    - '*.yandex.*'              # 所有 Yandex 应用
    - '!ru.yandex.browser'      # 除 Yandex 浏览器
    - 're:^org\.mozilla\..+$'   # 所有 Mozilla 应用
```

---

## 📥 来自文件与 URL 的列表

较长的列表适合放在外部 —— 每行一个包名或选择器。

**来自文件：**

```yaml
tun:
  enable: true
  include-package-file:
    - lists/allowed-apps.txt
```

**通过 HTTP(S) 从 URL：**

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

> 💾 URL 列表会缓存在本地，地址不可用时继续沿用。

---

## ⚙️ 底层如何工作

1. 📖 FlClashM 读取配置中的 `tun` 段。
2. 🔎 把选择器（通配符、正则）解析为具体的已安装包。
3. 🧱 生成访问控制规则。
4. 🏆 这些规则优先于手动设置。

---

> 📎 「由配置管理」指示器究竟显示什么、以及为何它读取 VPN 服务的快照而非当前内核配置 —— 见[运行时](../development/runtime.md#-android-vpn-应用参数快照)。
>
> 🌍 其他语言：[Русский](../../../ru/docs/user-guide/split-tunneling.md) · [English](../../../en/docs/user-guide/split-tunneling.md) · [فارسی](../../../fa/docs/user-guide/split-tunneling.md)
