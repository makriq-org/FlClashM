import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flclashx/product/backend/backend_edits.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal catalog with per-profile compare-and-set like the Go repository.
class EditsHost {
  int revision = 1;
  final profiles = <String, Map<String, dynamic>>{
    'one': {'id': 'one', 'label': 'One'},
    'two': {'id': 'two', 'label': 'Two'},
  };
  final revisions = <String, int>{'one': 1, 'two': 1};
  final commands = <(String, Map<String, dynamic>)>[];

  /// Concurrent writes (proxy selection, subscription refresh) that land
  /// right before the next profile.put.
  int concurrentWrites = 0;

  void write(String id, Map<String, dynamic> metadata) {
    revision++;
    revisions[id] = revision;
    profiles[id] = {...profiles[id]!, ...metadata};
  }

  Map<String, dynamic> get snapshot => {
    'apiVersion': 1,
    'seq': revision,
    'runtime': {'instanceId': 'service', 'appliedGeneration': 1},
    'catalog': {
      'revision': revision,
      'settings': <String, dynamic>{},
      'profiles': [
        for (final entry in profiles.entries)
          {'metadata': entry.value, 'revision': revisions[entry.key]},
      ],
    },
  };

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    final method = request['method'] as String;
    final params = Map<String, dynamic>.from(request['params'] as Map? ?? {});
    Object? result;
    switch (method) {
      case 'snapshot':
        result = snapshot;
      case 'runtime.view':
        result = <String, dynamic>{};
      case 'profile.put':
        commands.add((method, params));
        final metadata = Map<String, dynamic>.from(params['metadata'] as Map);
        final id = metadata['id'] as String;
        if (concurrentWrites > 0) {
          concurrentWrites--;
          write(id, {'selectedMap': <String, dynamic>{'GLOBAL': 'Other'}});
        }
        if (params['expectedRevision'] != revisions[id]) {
          result = {
            'status': 'failed',
            'errorCode': 'failed',
            'error': 'profile revision changed',
          };
        } else {
          write(id, metadata);
          result = {'status': 'succeeded', 'revision': revision};
        }
      case 'profile.reorder':
        commands.add((method, params));
        result = {'status': 'succeeded'};
      default:
        throw StateError('Unexpected UI command: $method');
    }
    return {'apiVersion': 1, 'result': result};
  }
}

Map<String, dynamic> configOf(BackendClient client) => {
  'profiles': [
    for (final profile in client.settings['profiles'] as List)
      Map<String, dynamic>.from(profile as Map),
  ],
};

Map<String, dynamic> withProfile(
  Map<String, dynamic> config,
  String id,
  Map<String, dynamic> fields,
) => {
  'profiles': [
    for (final profile in config['profiles'] as List)
      if ((profile as Map)['id'] == id)
        {...Map<String, dynamic>.from(profile), ...fields}
      else
        profile,
  ],
};

Future<BackendClient> attached(EditsHost host) async {
  final client = BackendClient(
    transport: host.call,
    events: const Stream.empty(),
  );
  await client.attach();
  return client;
}

void main() {
  test(
    'UI-only profile fields are reapplied after a concurrent revision bump',
    () async {
      final host = EditsHost()..concurrentWrites = 1;
      final client = await attached(host);
      final errors = <Object>[];
      final edits = BackendEdits(
        client,
        onError: errors.add,
        onSettled: () {},
      );
      final before = configOf(client);
      edits.submit(
        before,
        withProfile(before, 'one', {
          'unfoldSet': ['GLOBAL'],
        }),
      );
      await edits.flush();
      expect(errors, isEmpty);
      final puts = host.commands.where((c) => c.$1 == 'profile.put').toList();
      expect(puts, hasLength(2));
      expect(
        (puts.last.$2['metadata'] as Map).keys,
        unorderedEquals(['id', 'unfoldSet']),
      );
      expect(host.profiles['one']!['unfoldSet'], ['GLOBAL']);
      // The concurrent selection survives: only the UI field was patched.
      expect(host.profiles['one']!['selectedMap'], {'GLOBAL': 'Other'});
      await client.detach();
    },
  );

  test('user-owned profile fields still fail on a revision conflict', () async {
    final host = EditsHost()..concurrentWrites = 1;
    final client = await attached(host);
    final errors = <Object>[];
    final edits = BackendEdits(client, onError: errors.add, onSettled: () {});
    final before = configOf(client);
    edits.submit(before, withProfile(before, 'one', {'label': 'Renamed'}));
    await edits.flush();
    expect(host.commands, hasLength(1));
    expect(
      errors.single,
      isA<BackendException>().having(
        (e) => e.isRevisionConflict,
        'conflict',
        isTrue,
      ),
    );
    expect(host.profiles['one']!['label'], 'One');
    await client.detach();
  });

  test('a failing settle callback does not stall later edits', () async {
    final host = EditsHost();
    final client = await attached(host);
    final errors = <Object>[];
    var settled = 0;
    final edits = BackendEdits(
      client,
      onError: errors.add,
      onSettled: () {
        settled++;
        if (settled == 1) throw StateError('projection failed');
      },
    );
    final before = configOf(client);
    final first = withProfile(before, 'one', {'label': 'First'});
    edits
      ..submit(before, first)
      ..submit(first, withProfile(first, 'one', {'label': 'Second'}));
    await edits.flush();
    expect(settled, 2);
    expect(edits.pending, isFalse);
    expect(host.profiles['one']!['label'], 'Second');
    expect(errors, hasLength(1));
    await client.detach();
  });

  test('reordering applies only the order to the latest records', () async {
    final host = EditsHost();
    final client = await attached(host);
    final errors = <Object>[];
    final edits = BackendEdits(client, onError: errors.add, onSettled: () {});
    // The sort sheet copies the records it shows.
    final opened = configOf(client)['profiles'] as List;
    // A subscription refresh lands while the sheet is open.
    host.write('one', {'lastUpdateDate': '2026-10-23T00:00:00.000Z'});
    await client.refresh();
    final latest = configOf(client);
    final ids = [
      for (final profile in opened.reversed) (profile as Map)['id'] as String,
    ];
    edits.submit(latest, {
      'profiles': BackendEdits.reorderByIds(
        [
          for (final profile in latest['profiles'] as List)
            Map<String, dynamic>.from(profile as Map),
        ],
        ids,
        (profile) => profile['id'] as String,
      ),
    });
    await edits.flush();
    expect(errors, isEmpty);
    expect(host.commands.map((c) => c.$1), ['profile.reorder']);
    expect(host.commands.single.$2['profileIds'], ['two', 'one']);
    expect(host.profiles['one']!['lastUpdateDate'], '2026-10-23T00:00:00.000Z');
    await client.detach();
  });

  test('reorder keeps unknown records and ignores vanished ids', () {
    expect(
      BackendEdits.reorderByIds(['a', 'b', 'c'], ['c', 'gone', 'a'], (v) => v),
      ['c', 'a', 'b'],
    );
  });
}
