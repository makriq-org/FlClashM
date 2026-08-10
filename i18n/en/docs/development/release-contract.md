# 📦 Releases

## 🏷 Version rules

| | Format |
|---|--------|
| **Stable tag** | `v<versionName>` |
| **Pre-release** | `v<versionName>-<suffix>` |
| **`applicationId`** | `com.makriq.flclash` |

## 📂 Release contents

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

> [!IMPORTANT]
> Each release includes a `.sha256` for every file. For a stable release, their presence is additionally treated as a **mandatory part** of the release contract.

## 🚀 Pipeline

1. ✅ Product-boundary, upstream-drift, test, and analysis checks
2. 🔁 Release-continuity check
3. 🏗 Build the artifacts
4. 🧾 Verify the signature of all APKs and the AAB
5. 📝 Generate metadata
6. 🔢 Generate checksums
7. ✍️ Build and sign the Ed25519 update manifest
8. ☁️ Publish the APKs and manifest to SourceForge
9. 🐙 Publish to GitHub

## 📥 App update delivery

SourceForge `flclashm` is the **primary** APK delivery channel, GitHub is the **fallback**. The app reads fixed pointers:

- `https://flclashm.sourceforge.io/update/stable.json`
- `https://flclashm.sourceforge.io/update/pre.json`

For each pointer a binary `.sig` signature is published alongside. The signature is verified with a built-in **Ed25519 public key before the JSON is parsed**. The manifest contains the SHA-256 and an ordered mirror list for each ABI APK. Provider headers are **not** used to determine trust.

Release files are first uploaded into the immutable `releases/<tag>` directory. Then the pointer signature is published, and **last** — the pointer itself.

> [!IMPORTANT]
> A release requires the secrets `APP_UPDATE_SIGNING_KEY`, `SOURCEFORGE_SSH_KEY`, and `SOURCEFORGE_USERNAME`.

## ⏮ Rollback

The app remembers the highest `versionCode` and publication time **separately per channel** and rejects a replay of an old signed manifest. Therefore:

- a rollback is done **only via a new fixing release** with a higher `versionCode`;
- an already-installed APK can't be downgraded by Android either;
- when changing the manifest key, a **transitional** app version with the new public key is released first.

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/release-contract.md) · [中文](../../../zh/docs/development/release-contract.md) · [فارسی](../../../fa/docs/development/release-contract.md)
