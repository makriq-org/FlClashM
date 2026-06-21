# 分流

FlClashM 允许您控制哪些应用使用 VPN，哪些不使用。这可以通过两种方式配置：在应用设置中手动配置，或直接在 YAML 配置文件中配置。

## 通过配置文件实现分流

提供商可以直接在配置文件中指定分流规则。这些规则优先于用户的手动设置。

### 白名单：仅选定的应用

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

只有列出的应用将使用 VPN。

### 黑名单：排除选定的应用

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

列出的应用将不使用 VPN。

> 不能同时使用 `include-package` 和 `exclude-package`。

## 选择器格式

除了精确的包名外，还支持通配符和正则表达式：

| 格式 | 示例 | 描述 |
|------|------|------|
| 精确名称 | `com.termux` | 精确匹配 |
| 通配符 | `*.yandex.*` | 所有 Yandex 应用 |
| 正则表达式 | `re:^org\.mozilla\..+$` | 所有 Mozilla 应用 |
| 排除 | `!ru.yandex.browser` | 从列表中排除 |

### 通配符和排除示例

```yaml
tun:
  enable: true
  exclude-package:
    - '*.yandex.*'              # 所有 Yandex 应用
    - '!ru.yandex.browser'      # 除 Yandex 浏览器外
    - 're:^org\.mozilla\..+$'   # 所有 Mozilla 应用
```

## 从文件加载列表

包列表可以存储在单独的文件中：

```yaml
tun:
  enable: true
  include-package-file:
    - lists/allowed-apps.txt
```

文件必须每行包含一个包名或选择器。

## 从 URL 加载列表

列表可以通过 HTTP(S) 获取：

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

列表会缓存在本地，当 URL 不可用时使用。

## 工作原理

1. FlClashM 从配置文件中读取 `tun` 部分。
2. 将选择器（通配符、正则表达式）解析为具体的已安装包。
3. 创建访问控制规则。
4. 这些规则优先于手动设置。

如果配置文件定义了分流，应用设置中将显示访问控制由配置文件管理。
