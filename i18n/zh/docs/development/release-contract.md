# 📦 发布

## 🏷 版本规则

| | 格式 |
|---|------|
| **稳定标签** | `v<versionName>` |
| **预发布** | `v<versionName>-<suffix>` |
| **`applicationId`** | `com.makriq.flclash` |

## 📂 发布内容

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

> 🔐 每个发布都为每个文件附带 `.sha256`。对稳定发布，它们的存在还被视为发布契约的**必要部分**。

## 🚀 流水线

1. ✅ 产品边界、上游漂移、测试与分析检查
2. 🔁 发布连续性检查
3. 🏗 构建产物
4. 🧾 验证所有 APK 与 AAB 的签名
5. 📝 生成元数据
6. 🔢 生成校验和
7. ✍️ 构建并签名 Ed25519 更新清单
8. ☁️ 将 APK 与清单发布到 SourceForge
9. 🐙 发布到 GitHub

## 📥 应用更新分发

SourceForge `flclashm` 是 APK 的**主**分发通道，GitHub 为**备用**。应用读取固定指针：

- `https://flclashm.sourceforge.io/update/stable.json`
- `https://flclashm.sourceforge.io/update/pre.json`

每个指针旁会发布一个二进制 `.sig` 签名。签名在**解析 JSON 之前**用内置 **Ed25519 公钥**验证。清单包含每个 ABI APK 的 SHA-256 与有序镜像列表。提供商请求头**不**用于判定信任。

发布文件先上传到不可变目录 `releases/<tag>`。随后发布指针签名，**最后**才是指针本身。

> 🔑 发布需要机密 `APP_UPDATE_SIGNING_KEY`、`SOURCEFORGE_SSH_KEY` 和 `SOURCEFORGE_USERNAME`。

## ⏮ 回滚

应用**按通道分别**记住最高的 `versionCode` 与发布时间，并拒绝旧的已签名清单被重放。因此：

- 回滚**只能通过更高 `versionCode` 的新修复发布**进行；
- 已安装的 APK 也无法被 Android 降级；
- 更换清单密钥时，先发布一个带新公钥的**过渡**应用版本。

---

> 🌍 其他语言：[Русский](../../../ru/docs/development/release-contract.md) · [English](../../../en/docs/development/release-contract.md) · [فارسی](../../../fa/docs/development/release-contract.md)
