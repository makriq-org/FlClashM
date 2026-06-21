# Releases

## Version rules

- **Stable tag:** `v<versionName>`
- **Pre-release:** `v<versionName>-<suffix>`
- `applicationId`: `com.makriq.flclash`

## Release contents

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

A stable release includes `.sha256` checksums for every file.

## Pipeline

1. Continuity check
2. Build artifacts
3. Signature verification
4. Metadata generation
5. Checksum generation (stable)
6. Publish to GitHub
