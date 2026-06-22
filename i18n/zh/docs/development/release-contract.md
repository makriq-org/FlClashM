# 发布

## 版本规则

- **稳定标签：** `v<versionName>`
- **预发布：** `v<versionName>-<suffix>`
- `applicationId`: `com.makriq.flclash`

## 发布内容

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

稳定发布包含每个文件的 `.sha256` 校验和。

## 流程

1. 连续性检查
2. 构建产物
3. 签名验证
4. 元数据生成
5. 校验和生成（稳定版）
6. 发布到 GitHub
