import 'package:flclashx/product/services/app_update_release.dart';
import 'package:flutter_test/flutter_test.dart';

AppRelease createRelease(
  List<ReleaseAsset> assets, {
  String tagName = 'v1.2.3',
  int? versionCode,
  String? minimumVersion,
  int? minimumVersionCode,
}) => AppRelease(
  tagName: tagName,
  body: '',
  htmlUrl: 'https://example.com/releases/$tagName',
  assets: assets,
  prerelease: tagName.contains('-'),
  draft: false,
  versionCode: versionCode,
  minimumVersion: minimumVersion,
  minimumVersionCode: minimumVersionCode,
);

void main() {
  group('selectAndroidReleaseAsset', () {
    test('prefers exact ABI APK over universal fallback', () {
      final release = createRelease([
        ReleaseAsset(
          name: 'FlClashM-android-arm64-v8a.apk',
          browserDownloadUrl: 'https://example.com/arm64.apk',
          size: 1,
        ),
        ReleaseAsset(
          name: 'FlClashM-android-arm64-v8a.apk.sha256',
          browserDownloadUrl: 'https://example.com/arm64.apk.sha256',
          size: 1,
        ),
        ReleaseAsset(
          name: 'FlClashM-android-universal.apk',
          browserDownloadUrl: 'https://example.com/universal.apk',
          size: 1,
        ),
      ]);

      final asset = selectAndroidReleaseAsset(
        release,
        supportedAbis: const ['arm64-v8a', 'armeabi-v7a'],
      );

      expect(asset?.apkAsset.name, 'FlClashM-android-arm64-v8a.apk');
      expect(asset?.abi, 'arm64-v8a');
      expect(
        asset?.checksumAsset?.name,
        'FlClashM-android-arm64-v8a.apk.sha256',
      );
    });

    test('uses universal APK and its sha256 when no ABI-specific APK exists',
        () {
      final release = createRelease([
        ReleaseAsset(
          name: 'FlClashM-android-armeabi-v7a.apk',
          browserDownloadUrl: 'https://example.com/armeabi-v7a.apk',
          size: 1,
        ),
        ReleaseAsset(
          name: 'FlClashM-android-universal.apk',
          browserDownloadUrl: 'https://example.com/universal.apk',
          size: 1,
        ),
        ReleaseAsset(
          name: 'FlClashM-android-universal.apk.sha256',
          browserDownloadUrl: 'https://example.com/universal.apk.sha256',
          size: 1,
        ),
      ]);

      final asset = selectAndroidReleaseAsset(
        release,
        supportedAbis: const ['x86_64'],
      );

      expect(asset?.apkAsset.name, 'FlClashM-android-universal.apk');
      expect(asset?.abi, 'universal');
      expect(
        asset?.checksumAsset?.name,
        'FlClashM-android-universal.apk.sha256',
      );
    });

    test('returns null when there is neither a matching ABI nor a universal',
        () {
      final release = createRelease([
        ReleaseAsset(
          name: 'FlClashM-android-armeabi-v7a.apk',
          browserDownloadUrl: 'https://example.com/armeabi-v7a.apk',
          size: 1,
        ),
      ]);

      expect(
        selectAndroidReleaseAsset(release, supportedAbis: const ['x86_64']),
        isNull,
      );
    });

    test('never selects an Android AAB as installable asset', () {
      final release = createRelease([
        ReleaseAsset(
          name: 'FlClashM-android-release.aab',
          browserDownloadUrl: 'https://example.com/release.aab',
          size: 1,
        ),
      ]);

      expect(
        selectAndroidReleaseAsset(release, supportedAbis: const ['arm64-v8a']),
        isNull,
      );
    });
  });

  test('checks the package code of the selected ABI APK', () {
    final release = createRelease(
      [
        ReleaseAsset(
          name: 'FlClashM-android-arm64-v8a.apk',
          browserDownloadUrl: 'https://example.com/app.apk',
          size: 1,
          versionCode: 2026083802,
        ),
      ],
      tagName: 'v0.1.0',
      versionCode: 2026085802,
    );

    expect(
      isAppReleaseUpdateAvailable(
        release,
        installedVersionCode: 2026083801,
        installedVersionName: '0.10.8',
        supportedAbis: const ['arm64-v8a'],
      ),
      isTrue,
    );
    expect(
      isAppReleaseUpdateAvailable(
        release,
        installedVersionCode: 2026083802,
        installedVersionName: '0.10.8',
        supportedAbis: const ['arm64-v8a'],
      ),
      isFalse,
    );
  });

  test('uses Android version code when visible versions restart', () {
    final previous = createRelease(
      const [],
      tagName: 'v0.10.8-pre4',
      versionCode: 2026081601,
    );
    final restarted = createRelease(
      const [],
      tagName: 'v0.1.0',
      versionCode: 2026081801,
    );

    expect(
      selectLatestAppRelease([previous, restarted], includePrerelease: true)
          ?.tagName,
      'v0.1.0',
    );
  });

  test('selects the latest pre-release only when requested', () {
    final stable = createRelease(const [], versionCode: 1);
    final preRelease = createRelease(
      const [],
      tagName: 'v1.2.4-pre10',
      versionCode: 2,
    );

    expect(
      selectLatestAppRelease(
        [stable, preRelease],
        includePrerelease: false,
      )?.tagName,
      'v1.2.3',
    );
    expect(
      selectLatestAppRelease([stable, preRelease], includePrerelease: true)
          ?.tagName,
      'v1.2.4-pre10',
    );
  });

  group('isAppUpdateRequired', () {
    test('uses the signed minimum version code when both sides are known', () {
      final release = createRelease(
        const [],
        versionCode: 2026111801,
        minimumVersionCode: 2026110101,
      );

      expect(
        isAppUpdateRequired(
          release,
          installedVersionCode: 2026110100,
          installedVersionName: '1.0.0',
        ),
        isTrue,
      );
      expect(
        isAppUpdateRequired(
          release,
          installedVersionCode: 2026110101,
          installedVersionName: '1.0.0',
        ),
        isFalse,
      );
    });

    test('falls back to the visible minimum version', () {
      final release = createRelease(
        const [],
        versionCode: 2026111801,
        minimumVersion: '1.2.0',
      );

      expect(
        isAppUpdateRequired(
          release,
          installedVersionCode: null,
          installedVersionName: '1.1.9',
        ),
        isTrue,
      );
      expect(
        isAppUpdateRequired(
          release,
          installedVersionCode: null,
          installedVersionName: '1.2.0',
        ),
        isFalse,
      );
    });

    test('an unsigned fallback never makes an update required', () {
      final fallback = createRelease(const [], versionCode: 2026111801);

      expect(
        isAppUpdateRequired(
          fallback,
          installedVersionCode: 1,
          installedVersionName: '0.0.1',
        ),
        isFalse,
      );
    });
  });

  test('expected version code prefers the APK entry over the release code', () {
    final release = createRelease(
      [
        ReleaseAsset(
          name: 'FlClashM-android-arm64-v8a.apk',
          browserDownloadUrl: 'https://example.com/app.apk',
          size: 1,
          versionCode: 2026083802,
        ),
      ],
      versionCode: 2026085802,
    );
    final asset = selectAndroidReleaseAsset(
      release,
      supportedAbis: const ['arm64-v8a'],
    );

    expect(expectedAppUpdateVersionCode(release, asset!), 2026083802);
  });

  test('parses a checksum sidecar entry for the selected asset', () {
    final digest = 'a' * 64;

    expect(
      parseSha256Content(
        '${'b' * 64}  FlClashM-android-universal.apk\n'
        '$digest  FlClashM-android-arm64-v8a.apk\n',
        assetName: 'FlClashM-android-arm64-v8a.apk',
      ),
      digest,
    );
  });
}
