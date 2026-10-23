<div align="center">

<img src="../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="112" height="112">

# FlClashM

**在一个 Android 应用中使用 VPN 与网络封锁规避工具。**

[![Release](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases) [![GPL-3.0](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)

[Русский](../../README.md) · [English](../en/README.md) · **中文** · [فارسی](../fa/README.md)

</div>

基于 [FlClashX](https://github.com/pluralplay/FlClashX) 的 mihomo 客户端，可直接从配置启动 ByeDPI、OlcRTC、StormDNS 和 NaiveProxy，支持订阅、应用分流、VPN 快捷开关和经过验证的 APK 更新。

> [!NOTE]
> 项目仍在积极开发，部分功能尚在完善。

## 📥 下载

从 [GitHub Releases](https://github.com/makriq-org/FlClashM/releases) 下载 APK。不确定设备架构时选择 universal。

| 文件 | 设备 |
|---|---|
| `FlClashM-android-universal.apk` | 所有受支持架构 |
| `FlClashM-android-arm64-v8a.apk` | 多数现代手机 |
| `FlClashM-android-armeabi-v7a.apk` | 32 位 ARM 设备 |
| `FlClashM-android-x86_64.apk` | 模拟器与 x86_64 设备 |
| `FlClashM-android-release.aab` | Android App Bundle |

应用验证更新目录签名及 APK 的 SHA-256。开启相应设置后，更新列表会显示预发布版本。

## 🚀 连接

1. 安装 APK，通过链接、文件或二维码添加订阅。
2. 选择配置并连接，首次运行时允许建立 VPN。
3. 使用配置规则、全局代理选择或直连模式。

## 📚 两份指南

| 指南 | 内容 |
|---|---|
| [🧩 配置指南](docs/profiles.md) | 节点示例、应用分流、订阅响应头 |
| [🛠 构建与维护](docs/maintenance.md) | 命令、架构、安全、诊断与发布 |

## 💬 报告问题

创建 [issue](https://github.com/makriq-org/FlClashM/issues)，附应用版本、Android/ABI、步骤及预期结果。可在日志页导出诊断 ZIP。请勿公开订阅、密钥或密码。

## 🙏 致谢与许可

感谢以下项目的作者： [FlClashX](https://github.com/pluralplay/FlClashX), [mihomo](https://github.com/MetaCubeX/mihomo), [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc), [StormDNS](https://github.com/nullroute1970/StormDNS), [NaiveProxy](https://github.com/klzgrad/naiveproxy).

应用采用 [GPL-3.0](../../LICENSE)。第三方内核与二进制保留各自许可。版本历史见 [CHANGELOG](../../CHANGELOG.md)。
