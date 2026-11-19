import 'dart:async';
import 'dart:io';

import 'package:flclashx/common/task.dart';
import 'package:flclashx/core/controller.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedCore implements CoreController {
  final pending = Completer<({ProfileBase base, String path})>();

  @override
  Future<({ProfileBase base, String path})> getProfileBase(String id) =>
      pending.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final type in ['custom', 'script']) {
    test('late file metadata cannot manage a $type profile', () async {
      final core = _DelayedCore();
      final container = ProviderContainer(
        overrides: [
          currentProfileProvider.overrideWith((_) => null),
          coreHandlerProvider.overrideWith((_) => core),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(profileSettingsActionProvider.notifier);
      // Let the provider's initial null-profile synchronization settle first.
      await Future<void>.delayed(Duration.zero);
      final old = action.apply((
        id: 'file-a',
        updatedAt: null,
        type: ProfileType.file,
        extendType: ExtendType.standard,
      ));
      await action.apply((
        id: 'profile-b',
        updatedAt: null,
        type: type == 'custom' ? ProfileType.custom : ProfileType.file,
        extendType: type == 'script' ? ExtendType.script : ExtendType.standard,
      ));
      core.pending.complete((
        base: const ProfileBase(
          config: {'log-level': 'debug'},
          present: ['allow-lan', 'log-level'],
        ),
        path: '',
      ));
      await old;
      expect(container.read(managedClashKeysProvider), isEmpty);
      expect(container.read(profileSettingsActionProvider), isNull);
    });
  }

  test(
    'profile inspection projects its log level and clears it on deselection',
    () async {
      final core = _DelayedCore();
      final container = ProviderContainer(
        overrides: [
          currentProfileProvider.overrideWith((_) => null),
          coreHandlerProvider.overrideWith((_) => core),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(profileSettingsActionProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      core.pending.complete((
        base: const ProfileBase(
          config: {'log-level': 'debug'},
          present: ['log-level'],
        ),
        path: '',
      ));
      await action.apply((
        id: 'file-a',
        updatedAt: null,
        type: ProfileType.file,
        extendType: ExtendType.standard,
      ));
      expect(container.read(profileSettingsActionProvider), LogLevel.debug);
      await action.apply((
        id: null,
        updatedAt: null,
        type: null,
        extendType: null,
      ));
      expect(container.read(profileSettingsActionProvider), isNull);
    },
  );

  for (final entry in <(Object, int)>[
    (24, 24),
    (1, 1),
    // A dropped value leaves the app default, not the stored one.
    (0, 24),
    (-5, 24),
    (1000000, 24),
    ('24', 24),
  ]) {
    final interval = entry.$1;
    final kept = entry.$2;
    test('profile geo-update-interval $interval becomes $kept', () {
      final next = syncProfileSettings(
        const PatchClashConfig(geoUpdateInterval: 1),
        {'geo-update-interval': interval},
        ['geo-update-interval'],
      );
      expect(next.geoUpdateInterval, kept);
    });
  }

  test('legacy migration keeps a profile only when its id is a file name', () async {
    final directory = await Directory.systemTemp.createTemp('legacy-profile-');
    addTearDown(() => directory.delete(recursive: true));
    final source = Directory('${directory.path}/source')..createSync();
    Directory('${directory.path}/outside').createSync();
    File('${directory.path}/outside/secret.yaml').writeAsStringSync('secret: 1');
    final migrated = await migrateLegacyConfig(
      configMap: {
        'profiles': [
          {'id': '../outside/secret', 'autoUpdateDuration': 0},
          {'id': 'missing', 'autoUpdateDuration': 0},
        ],
      },
      sourcePath: source.path,
      targetPath: '${directory.path}/target',
    );
    expect(migrated.profiles.map((profile) => profile.id), ['missing']);
    expect(
      Directory('${directory.path}/target/profiles').existsSync(),
      isFalse,
    );
  });

  for (final selected in <Object?>['legacy-id', 17, null]) {
    test(
      'legacy migration preserves only string profile selection $selected',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'legacy-profile-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final migrated = await migrateLegacyConfig(
          configMap: {
            'currentProfileId': selected,
            'profiles': [
              {'id': 'legacy-id', 'autoUpdateDuration': 0},
            ],
          },
          sourcePath: '${directory.path}/source',
          targetPath: '${directory.path}/target',
        );
        expect(migrated.profiles.single.id, 'legacy-id');
        expect(
          migrated.configMap!['currentProfileId'],
          selected is String ? selected : null,
        );
      },
    );
  }
}
