import 'package:flutter_test/flutter_test.dart';

import '../../tool/android_apk_version_codes.dart';
import '../../tool/release_contract.dart';
import '../../tool/write_release_metadata.dart';

void main() {
  test('publishes base, maximum and per-APK version codes', () {
    final contract = readReleaseContract();
    final metadata = buildReleaseMetadata(
      contract: contract,
      pubspecVersion: parsePubspecVersion(
        'version: 0.1.1+2026082401\n',
        path: 'pubspec.yaml',
      ),
      coreVersion: 'v1.2.3',
      options: const MetadataOptions(
        outputPath: 'dist/metadata.json',
        githubRefName: 'v0.1.1',
        githubSha: 'abc123',
        githubRepository: 'makriq-org/FlClashM',
        releaseChannel: 'stable',
        distPath: 'dist',
      ),
      apkVersionCodes: AndroidApkVersionCodes({
        'FlClashM-android-universal.apk': 2026082401,
        'FlClashM-android-arm64-v8a.apk': 2026084401,
        'FlClashM-android-x86_64.apk': 2026086401,
      }),
    );

    expect(metadata['baseVersionCode'], 2026082401);
    expect(metadata['versionCode'], 2026086401);
    expect(
      (metadata['apkVersionCodes'] as Map)['FlClashM-android-arm64-v8a.apk'],
      2026084401,
    );
  });
}
