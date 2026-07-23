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
