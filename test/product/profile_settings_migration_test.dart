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
        base: const ProfileBase(config: {}, present: ['allow-lan']),
        path: '',
      ));
      await old;
      expect(container.read(managedClashKeysProvider), isEmpty);
    });
  }

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
