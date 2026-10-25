import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flclashx/database/database.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

class AuthoringHost {
  int revision = 1;
  bool conflict = false;
  final methods = <String>[];
  Map<String, dynamic> collections = {
    for (final name in [
      'scripts',
      'rules',
      'disabledRules',
      'proxyGroups',
      'clashProviders',
      'customProxies',
      'proxyDialers',
      'iconRecords',
      'iconSets',
    ])
      name: <dynamic>[],
  };
  List<Map<String, dynamic>> profiles = [
    const Profile(
      id: 'opaque/профиль:01',
      label: 'Before',
      autoUpdateDuration: Duration.zero,
    ).toJson(),
  ];
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    final method = request['method'] as String;
    methods.add(method);
    dynamic result;
    switch (method) {
      case 'snapshot':
        result = {
          'seq': revision,
          'runtime': {'instanceId': 'go', 'appliedGeneration': 0},
          'catalog': {
            'revision': revision,
            'profiles': [
              for (final p in profiles) {'metadata': p, 'revision': revision},
            ],
            'settings': {},
          },
        };
      case 'runtime.view':
        result = {};
      case 'authoring.snapshot':
        result = {
          'revision': revision,
          'profiles': profiles,
          'collections': collections,
        };
      case 'authoring.replace':
        final params = request['params'] as Map;
        if (conflict || params['expectedRevision'] != revision) {
          return {
            'apiVersion': 1,
            'error': {
              'code': 'conflict',
              'message': 'authoring revision changed',
            },
          };
        }
        collections = copy(
          Map<String, dynamic>.from(params['collections'] as Map),
        );
        profiles = [
          for (final p in params['profiles'] as List)
            Map<String, dynamic>.from(p as Map),
        ];
        result = {'status': 'succeeded', 'revision': ++revision};
      default:
        throw StateError('Unexpected method $method');
    }
    return {'apiVersion': 1, 'result': jsonDecode(jsonEncode(result))};
  }
}

void main() {
  test('CAS failure rolls back profile metadata and all authoring drafts', () async {
    final host = AuthoringHost();
    final client = BackendClient(
      transport: host.invoke,
      events: const Stream.empty(),
    );
    final db = Database.backend(client, executor: NativeDatabase.memory());
    addTearDown(db.close);
    await client.attach();
    await db.refreshFromGo();
    final before = await db.profilesDao.query().get();
    host.conflict = true;
    await expectLater(
      db.transaction(() async {
        await db.profiles.put(
          before.single.copyWith(label: 'Draft').toCompanion(),
        );
        await db.scripts.put(
          Script(
            id: 7,
            label: 'Draft script',
            lastUpdateTime: DateTime.utc(2026),
            source: 'function main(c){return c;}',
          ).toCompanion(),
        );
      }),
      throwsA(
        isA<BackendException>().having(
          (e) => e.isRevisionConflict,
          'conflict',
          isTrue,
        ),
      ),
    );
    expect((await db.profilesDao.query().get()).single.label, 'Before');
    expect(await db.scriptsDao.query().get(), isEmpty);
    expect(host.profiles.single['label'], 'Before');
    expect(host.collections['scripts'], isEmpty);
    expect(
      host.methods.where((m) => m == 'profile.put' || m == 'profile.delete'),
      isEmpty,
    );
    // An independent Go write replaces the complete projection, preserving IDs.
    host.conflict = false;
    host.revision++;
    host.profiles.single['label'] = 'From Go';
    await client.refresh();
    await db.refreshFromGo();
    final recovered = (await db.profilesDao.query().get()).single;
    expect(recovered.label, 'From Go');
    expect(recovered.id, 'opaque/профиль:01');
    await client.detach();
  });
  test(
    'successful form commit reads back the authoritative Go snapshot',
    () async {
      final host = AuthoringHost();
      final client = BackendClient(
        transport: host.invoke,
        events: const Stream.empty(),
      );
      final db = Database.backend(client, executor: NativeDatabase.memory());
      addTearDown(db.close);
      await client.attach();
      await db.refreshFromGo();
      final profile = (await db.profilesDao.query().get()).single;
      await db.transaction(() async {
        await db.profiles.put(profile.copyWith(label: 'Saved').toCompanion());
        await db.scripts.put(
          Script(
            id: 7,
            label: 'Script',
            lastUpdateTime: DateTime.utc(2026),
            source: 'function main(c){return c;}',
          ).toCompanion(),
        );
      });
      expect(host.revision, 2);
      expect(host.profiles.single['label'], 'Saved');
      expect((await db.profilesDao.query().get()).single.label, 'Saved');
      expect(
        (await db.scriptsDao.query().get()).single.source,
        'function main(c){return c;}',
      );
      expect(host.methods.where((m) => m == 'authoring.replace'), hasLength(1));
      expect(host.methods.last, 'authoring.snapshot');
      await client.detach();
    },
  );
}
