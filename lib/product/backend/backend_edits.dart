import 'dart:async';
import 'dart:convert';

import 'backend_client.dart';

/// Translates changes made by UI controls into domain commands. Pending values
/// are UI drafts; only the backend decides when and how they affect runtime.
class BackendEdits {
  BackendEdits(this.client, {required this.onError, required this.onSettled});
  final BackendClient client;
  final void Function(Object error) onError;
  final void Function() onSettled;
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  final _ownRevisions = <String, Map<int, int>>{};
  bool get pending => _pending > 0;
  Future<void> flush() => _tail;

  void submit(
    Map<String, dynamic> beforeConfig,
    Map<String, dynamic> afterConfig,
  ) {
    final before = _copy(beforeConfig);
    final after = _copy(afterConfig);
    final commands = <(String, Map<String, dynamic>)>[];
    final settingsBefore = {...before}
      ..remove('profiles')
      ..remove('currentProfileId');
    final settingsAfter = {...after}
      ..remove('profiles')
      ..remove('currentProfileId');
    final patch = _patch(settingsBefore, settingsAfter);
    if (patch.isNotEmpty) {
      commands.add(('settings.patch', {'patch': patch}));
    }

    final oldProfiles = _profiles(before);
    final nextProfiles = _profiles(after);
    for (final id in oldProfiles.keys.where(
      (id) => !nextProfiles.containsKey(id),
    )) {
      commands.add((
        'profile.delete',
        {'profileId': id, 'expectedRevision': client.profileRevision(id)},
      ));
    }
    for (final entry in nextProfiles.entries) {
      final old = oldProfiles[entry.key];
      // Source imports create records in the backend.
      if (old == null) {
        continue;
      }
      final patch = _patch(old, entry.value);
      if (patch.isEmpty) {
        continue;
      }
      commands.add((
        'profile.put',
        {
          'metadata': {'id': entry.key, ...patch},
          'expectedRevision': client.profileRevision(entry.key),
        },
      ));
    }
    if (before['currentProfileId'] != after['currentProfileId']) {
      commands.add((
        'profile.select',
        {'profileId': after['currentProfileId']},
      ));
    }
    final retained = oldProfiles.keys.where(nextProfiles.containsKey).toList();
    final reordered = nextProfiles.keys.where(oldProfiles.containsKey).toList();
    if (!_same(retained, reordered) && retained.length == nextProfiles.length) {
      commands.add((
        'profile.reorder',
        {'profileIds': nextProfiles.keys.toList()},
      ));
    }
    if (commands.isEmpty) {
      return;
    }
    _pending++;
    _tail = _tail.then((_) async {
      try {
        for (final command in commands) {
          final params = {...command.$2};
          final metadata = params['metadata'];
          final profileId = metadata is Map
              ? metadata['id'] as String?
              : params['profileId'] as String?;
          var expected = params['expectedRevision'] as int?;
          if (profileId != null && expected != null) {
            final advances = _ownRevisions[profileId];
            while (advances?.containsKey(expected) == true) {
              expected = advances[expected]!;
            }
            params['expectedRevision'] = expected;
          }
          if (command.$1 == 'profile.reorder') {
            params['expectedRevision'] = client.catalogRevision;
          }
          final receipt = await client.command(command.$1, params);
          if (command.$1 == 'profile.put' &&
              profileId != null &&
              expected != null) {
            final revision = (receipt['revision'] as num?)?.toInt();
            if (revision != null && revision > expected) {
              (_ownRevisions[profileId] ??= {})[expected] = revision;
            }
          }
        }
      } catch (error) {
        onError(error);
      } finally {
        try {
          await client.refresh();
        } catch (error) {
          onError(error);
        }
        _pending--;
        if (_pending == 0) {
          _ownRevisions.clear();
        }
        onSettled();
      }
    });
  }

  static Map<String, Map<String, dynamic>> _profiles(
    Map<String, dynamic> config,
  ) => {
    for (final value in config['profiles'] as List? ?? [])
      if (value is Map && value['id'] is String)
        value['id'] as String: Map<String, dynamic>.from(value),
  };

  // These are structured settings objects in the backend storage contract.
  // Dictionaries and arrays are replaced as a whole, including explicit empty.
  static const _objects = {
    'appSetting',
    'patchClashConfig',
    'networkProps',
    'vpnProps',
    'themeProps',
    'proxiesStyle',
    'windowProps',
    'scriptProps',
    'textScale',
    'tun',
    'dns',
    'geox-url',
    'fallback-filter',
    'accessControl',
    'overrideData',
    'rule',
  };
  static Map<String, dynamic> _patch(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) => {
    for (final entry in after.entries)
      if (!_same(before[entry.key], entry.value))
        entry.key:
            _objects.contains(entry.key) &&
                before[entry.key] is Map &&
                entry.value is Map
            ? _patch(
                Map<String, dynamic>.from(before[entry.key] as Map),
                Map<String, dynamic>.from(entry.value as Map),
              )
            : entry.value,
  };
  static bool _same(dynamic left, dynamic right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) => right.containsKey(key) && _same(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(
            left.length,
            (index) => _same(left[index], right[index]),
          ).every((same) => same);
    }
    return left == right;
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
}
