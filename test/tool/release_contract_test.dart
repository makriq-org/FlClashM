import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_contract.dart';

void main() {
  group('parsePubspecVersion', () {
    test('parses a stable version', () {
      final version = parsePubspecVersion(
        'version: 1.2.3+2026081001',
        path: 'pubspec.yaml',
      );

      expect(version.versionName, '1.2.3');
      expect(version.versionCode, 2026081001);
      expect(version.tagName, 'v1.2.3');
      expect(version.stableTagName, 'v1.2.3');
      expect(version.releaseChannel, 'stable');
    });

    test('parses a full prerelease version', () {
      final version = parsePubspecVersion(
        'version: 1.2.3-pre4+2026081002',
        path: 'pubspec.yaml',
      );

      expect(version.versionName, '1.2.3-pre4');
      expect(version.versionCode, 2026081002);
      expect(version.tagName, 'v1.2.3-pre4');
      expect(version.stableTagName, 'v1.2.3');
      expect(version.releaseChannel, 'pre');
    });

    test('rejects an unsupported prerelease suffix', () {
      expect(
        () => parsePubspecVersion(
          'version: 1.2.3-beta1+2026081001',
          path: 'pubspec.yaml',
        ),
        throwsStateError,
      );
    });
  });

  group('validateReleaseTag', () {
    test('requires an exact prerelease tag', () {
      final version = parsePubspecVersion(
        'version: 1.2.3-pre4+2026081002',
        path: 'pubspec.yaml',
      );

      expect(
        validateReleaseTag(refName: 'v1.2.3-pre4', pubspecVersion: version),
        isNull,
      );
      expect(
        validateReleaseTag(refName: 'v1.2.3-pre5', pubspecVersion: version),
        isNotNull,
      );
    });
  });

  group('validateReleaseChannel', () {
    test('derives the channel from the full version', () {
      final version = parsePubspecVersion(
        'version: 1.2.3-pre4+2026081002',
        path: 'pubspec.yaml',
      );

      expect(
        validateReleaseChannel(
          releaseChannel: 'pre',
          pubspecVersion: version,
        ),
        isNull,
      );
      expect(
        validateReleaseChannel(
          releaseChannel: 'stable',
          pubspecVersion: version,
        ),
        isNotNull,
      );
    });
  });
}
