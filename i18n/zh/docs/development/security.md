# 🔒 安全策略

分支的关键不变量：**外观与提供商提示不能削弱运行时保护。**

## 🛡 运行时策略

`SecurityPolicy` 在 Android 上强制启用 TUN。该层不更改任何其他配置或运行时参数。

## 📱 Android 保护

- 🔌 强制启用 TUN。
- 🎯 配置中的分流优先。
- 📸 已应用包规则指示器读取 **Android VPN 服务的快照**，而非当前内核配置（见 [VPN 快照](runtime.md#-android-vpn-应用参数快照)）。
- ✍️ 应用更新清单在解析内容前，用内置 **Ed25519** 公钥验证。
- 🔐 更新下载器验证已签名清单中的 APK **SHA-256**，且只遍历其中列出的镜像。
- 🧾 APK 签名还会由 Android 安装器针对已安装应用的签名额外验证。
- 🚫 内置节点不能设置本地地址与端口。
- 📞 `olcrtc` 仅在 CNC 模式工作。
- 🧱 在 `olcrtc profiles[]` 中递归禁止 `socks.host`、`socks.port` 和 `crypto.key_file`；其余字段透明传给 OlcRTC。
- 🛡 `byedpi` 只检查指定的 URL。
- 🌪 `stormdns` 禁止使用由应用掌管的字段：监听器（`listen`、`listen-ip`、`listen-port`、`server`、`port`、`protocol`）、SOCKS5 认证、整个 `local-dns-*` 块、日志目录与文件名、`config-version` 以及 `startup.mode: ask`。

## 🌪 StormDNS 解析器列表

`stormdns` 是唯一由配置传入网络地址列表的节点，因此单独校验。

- ✅ `resolvers` 中允许的来源：`system`、IP、`IP:port`、CIDR 范围，以及指向列表的 `https://` 链接。
- 🔗 列表链接**仅接受 HTTPS**，不得包含 userinfo 与 fragment，不得为 `localhost` 或本地地址；响应上限为 **1 MiB** 与 **15 秒**。
- 💾 远程列表按链接分别缓存。来源不可达时使用最后一份副本 —— 即使 `refresh` 已过期；没有副本时该链接直接跳过，而不会让配置应用失败。
- 🧮 CIDR 展开上限为 65536 个地址：上游在大范围上会逐个遍历，那会让应用卡死。
- 🔁 最终列表按 IP 去重 —— 第一次出现者连同其端口胜出。
- ⚠️ 允许 `encryption: none` 与 `xor`，因为它们属于上游契约且服务端确实这样配置。它们**不会对解析器运营方隐藏载荷内容**；应用不作特别标记，这一点已在[内置节点指南](../user-guide/profiles.md)中说明。

## 🌐 连通性检查地址

对 `connectivity-check` 与 `strategy-test`，**只**允许不含凭据或本地目的地的 HTTP(S) 地址。

- 🚫 禁止环回、私有、链路本地、组播与保留段，以及本地名称。
- 🔁 网络请求前会重新验证 DNS 结果。
- 🔗 仅通过被验证节点的 SOCKS 命令与目的地建立连接。

## 🎨 提供商请求头

- 💡 `flclashm-*` 请求头保持**建议性**（见[提供商提示](../user-guide/provider-hints.md)）。
- 🔒 外观**不能**更改运行时保护。

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/security.md) · [English](../../../en/docs/development/security.md) · [فارسی](../../../fa/docs/development/security.md)
