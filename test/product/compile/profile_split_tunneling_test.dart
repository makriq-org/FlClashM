import 'dart:async';
import 'dart:io';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
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

    test('ignores local package lists without rejecting the Android profile',
        () async {
      final diagnostics = <String>[];

      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: {
          'tun': {
            'exclude-package-file': 'lists/exclude.txt',
          },
        },
        isAndroid: true,
        profilesPath: tempDir.path,
        profileId: 'profile-1',
        onIgnoredLocalPath: diagnostics.add,
      );

      expect(
          resolved.config['tun'].containsKey('exclude-package-file'), isFalse);
      expect(resolved.accessControl, isNull);
      expect(
        diagnostics,
        contains(
          'Android ignored unsupported local profile path '
          '`tun.exclude-package-file`.',
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

    test('returns a saved network list before one background refresh',
        () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      final rawConfig = {
        'tun': {
          'include-package-url': 'https://example.com/background.txt',
        },
      };
      await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-background',
        installedPackageNames: const ['com.cached.app'],
        readRemoteSource: (_) async => 'com.cached.app\n',
      );

      final refresh = Completer<String>();
      var refreshCalls = 0;
      Future<String> readRemote(String _) {
        refreshCalls++;
        return refresh.future;
      }

      final first = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-background',
        installedPackageNames: const ['com.cached.app'],
        readRemoteSource: readRemote,
      ).timeout(const Duration(seconds: 1));
      final second = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-background',
        installedPackageNames: const ['com.cached.app'],
        readRemoteSource: readRemote,
      ).timeout(const Duration(seconds: 1));

      expect(first.config['tun']['include-package'], ['com.cached.app']);
      expect(second.config['tun']['include-package'], ['com.cached.app']);
      expect(refreshCalls, 1);
      refresh.complete('com.cached.app\n');
      await Future<void>.delayed(const Duration(milliseconds: 10));
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

      final invalidRefreshStarted = Completer<void>();
      final cachedResolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: rawConfig,
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-cache-validated',
        installedPackageNames: const ['org.mozilla.firefox'],
        readRemoteSource: (_) async {
          invalidRefreshStarted.complete();
          return 're:[\n';
        },
      );
      expect(
        cachedResolved.config['tun']['include-package'],
        ['org.mozilla.firefox'],
      );
      await invalidRefreshStarted.future;
      await Future<void>.delayed(Duration.zero);

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

    test('bounds parallel source reads and preserves source order', () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      final urls = [
        for (var index = 0; index < 8; index++)
          'https://example.com/list-$index.txt',
      ];
      var activeReads = 0;
      var peakReads = 0;

      final resolved = await resolveAndroidProfileSplitTunneling(
        rawConfig: {
          'tun': {
            'include-package-url': urls,
          },
        },
        isAndroid: true,
        profilesPath: profilesDir.path,
        profileId: 'profile-parallel-sources',
        installedPackageNames: [
          for (var index = 0; index < urls.length; index++) 'com.example.$index',
        ],
        readRemoteSource: (url) async {
          final index = urls.indexOf(url);
          activeReads++;
          if (activeReads > peakReads) {
            peakReads = activeReads;
          }
          try {
            await Future<void>.delayed(
              Duration(milliseconds: (urls.length - index) * 2),
            );
            return 'com.example.$index\n';
          } finally {
            activeReads--;
          }
        },
      );

      expect(peakReads, 4);
      expect(
        resolved.config['tun']['include-package'],
        [for (var index = 0; index < urls.length; index++) 'com.example.$index'],
      );
    });

    test('ignores user-selected cache paths for remote package lists',
        () async {
      final profilesDir = Directory(path.join(tempDir.path, 'profiles'))
        ..createSync(recursive: true);
      final diagnostics = <String>[];

      final resolved = await resolveAndroidProfileSplitTunneling(
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
        installedPackageNames: const ['com.termux'],
        readRemoteSource: (_) async => 'com.termux\n',
        onIgnoredLocalPath: diagnostics.add,
      );

      expect(resolved.config['tun']['include-package'], ['com.termux']);
      expect(
          File(path.join(tempDir.path, 'outside.txt')).existsSync(), isFalse);
      expect(
        diagnostics,
        contains(
          'Android ignored unsupported local profile path '
          '`tun.include-package-url`.',
        ),
      );
    });
  });
}
