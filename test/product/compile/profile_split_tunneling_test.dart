import 'dart:io';

import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('profile split tunneling', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('profile-split-');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('restores raw client-only tun fields from profile YAML', () async {
      final profileFile = File(path.join(tempDir.path, 'profile.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
tun:
  exclude-package-url: https://example.com/packages.txt
  include-package-file:
    - lists/include.txt
''');

      final restored = await restoreAndroidProfileSplitTunnelingFields(
        {
          'tun': {'enable': true},
        },
        isAndroid: true,
        profilePath: profileFile.path,
      );

      expect(
        restored['tun']['exclude-package-url'],
        'https://example.com/packages.txt',
      );
      expect(
        restored['tun']['include-package-file'],
        ['lists/include.txt'],
      );
    });

    test('expands local package lists into an access-control override',
        () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      File(path.join(profilesDir.path, 'lists', 'exclude.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('org.telegram.messenger\ncom.android.chrome\n');

      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: {
          'tun': {
            'exclude-package-file': 'lists/exclude.txt',
          },
        },
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-1',
        installedPackageNames: const [
          'org.telegram.messenger',
          'com.android.chrome',
        ],
      );

      expect(
        resolved.config['tun']['exclude-package'],
        ['org.telegram.messenger', 'com.android.chrome'],
      );
      expect(
          resolved.config['tun'].containsKey('exclude-package-file'), isFalse);
      expect(
        resolved.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: ['org.telegram.messenger', 'com.android.chrome'],
        ),
      );
    });

    test('expands masks regex and exceptions against installed packages',
        () async {
      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: {
          'tun': {
            'exclude-package': [
              '*.yandex.*',
              '!ru.yandex.browser',
              r're:^org\.mozilla\..+$',
              'org.telegram.messenger',
            ],
          },
        },
        isAndroid: true,
        profilesPath: tempDir.path,
        profileId: 'profile-2',
        installedPackageNames: const [
          'ru.yandex.music',
          'ru.yandex.browser',
          'org.mozilla.firefox',
          'org.telegram.messenger',
        ],
      );

      expect(
        resolved.config['tun']['exclude-package'],
        ['ru.yandex.music', 'org.mozilla.firefox', 'org.telegram.messenger'],
      );
      expect(
        resolved.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.rejectSelected,
          rejectList: [
            'ru.yandex.music',
            'org.mozilla.firefox',
            'org.telegram.messenger',
          ],
        ),
      );
    });

    test(
        'keeps exact selectors when installed package inventory is unavailable',
        () async {
      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: {
          'tun': {
            'include-package': ['com.termux', '*.mozilla.*'],
          },
        },
        isAndroid: true,
        profilesPath: tempDir.path,
        profileId: 'profile-3',
      );

      expect(
        resolved.config['tun']['include-package'],
        ['com.termux'],
      );
      expect(
        resolved.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: ['com.termux'],
        ),
      );
    });

    test('keeps explicit include mode when selectors resolve to no packages',
        () async {
      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: {
          'tun': {
            'include-package': ['com.termux'],
          },
        },
        isAndroid: true,
        profilesPath: tempDir.path,
        profileId: 'profile-empty-include',
        installedPackageNames: const ['org.mozilla.firefox'],
      );

      expect(
        resolved.config['tun']['include-package'],
        <String>[],
      );
      expect(
        resolved.accessControl,
        const AccessControl(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: <String>[],
        ),
      );
    });

    test('rejects conflicting include and exclude modes', () async {
      await expectLater(
        () => resolveAndroidProfileSplitTunneling(
          rawConfig: {
            'tun': {
              'include-package': ['com.termux'],
              'exclude-package': ['org.telegram.messenger'],
            },
          },
          isAndroid: true,
          profilesPath: tempDir.path,
          profileId: 'profile-4',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('ambiguous'),
          ),
        ),
      );
    });

    test('uses cached URL-backed lists when the remote source is unavailable',
        () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      final rawConfig = {
        'tun': {
          'include-package-url': 'https://example.com/include.txt',
        },
      };

      final firstResolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-5',
        installedPackageNames: const ['org.mozilla.firefox'],
        readRemoteSource: (_) async => 'org.mozilla.firefox\n',
      );
      final cachedResolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-5',
        installedPackageNames: const ['org.mozilla.firefox'],
        readRemoteSource: (_) async => throw const SocketException('offline'),
      );

      expect(
        firstResolved.config['tun']['include-package'],
        ['org.mozilla.firefox'],
      );
      expect(
        cachedResolved.config['tun']['include-package'],
        ['org.mozilla.firefox'],
      );
    });

    test('keeps the last validated URL cache when a later fetch is invalid',
        () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      final rawConfig = {
        'tun': {
          'include-package-url': 'https://example.com/include.txt',
        },
      };

      await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-cache-validated',
        installedPackageNames: const ['org.mozilla.firefox'],
        readRemoteSource: (_) async => 'org.mozilla.firefox\n',
      );

      await expectLater(
        () => resolveAndroidProfileSplitTunneling(
          rawConfig: rawConfig,
          isAndroid: true,
          profilesPath: profilesDir.path,
          profileId: 'profile-cache-validated',
          installedPackageNames: const ['org.mozilla.firefox'],
          readRemoteSource: (_) async => 're:[\n',
        ),
        throwsA(isA<FormatException>()),
      );

      final fallbackResolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-cache-validated',
        installedPackageNames: const ['org.mozilla.firefox'],
        readRemoteSource: (_) async => throw const SocketException('offline'),
      );

      expect(
        fallbackResolved.config['tun']['include-package'],
        ['org.mozilla.firefox'],
      );
    });

    test('rejects cache paths outside the profiles directory', () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);

      await expectLater(
        () => resolveAndroidProfileSplitTunneling(
          rawConfig: {
            'tun': {
              'include-package-url': [
                {
                  'url': 'https://example.com/include.txt',
                  'path': '../outside.txt',
                },
              ],
            },
          },
          isAndroid: true,
          profilesPath: profilesDir.path,
          profileId: 'profile-6',
          readRemoteSource: (_) async => 'com.termux\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('must stay within the profiles directory'),
          ),
        ),
      );
    });
  });
}
