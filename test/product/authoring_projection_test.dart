import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart'
    show ApplyInterceptor, BatchedStatements, QueryExecutor, QueryInterceptor;

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
  bool failCleanup = false;
  bool failSnapshot = false;
  String instance = 'go';
  int sequence = 1;
  final blobs = <String, List<int>>{};
  List<dynamic> deletedProfileIds = [];
  Future<void> Function()? beforeAuthoringSnapshot;
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
          'seq': sequence,
          'runtime': {'instanceId': instance, 'appliedGeneration': 0},
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
        await beforeAuthoringSnapshot?.call();
        if (failSnapshot) throw StateError('Snapshot unavailable');
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
          Map<String, dynamic>.from(
            (params['token'] == null
                    ? params['collections']
                    : jsonDecode(utf8.decode(blobs[params['token']]!)))
                as Map,
          ),
        );
        deletedProfileIds = List<dynamic>.from(
          params['deletedProfileIds'] as List,
        );
        profiles = [
          for (final p in params['profiles'] as List)
            Map<String, dynamic>.from(p as Map),
        ];
        sequence++;
        result = {'status': 'succeeded', 'revision': ++revision};
      case 'blob.create':
        blobs['transfer'] = [];
        result = {'token': 'transfer'};
      case 'blob.append':
        final params = request['params'] as Map;
        blobs[params['token']]!.addAll(base64Decode(params['data'] as String));
        result = true;
      case 'blob.delete':
        if (failCleanup) throw StateError('Cleanup unavailable');
        blobs.remove((request['params'] as Map)['token']);
        result = true;
      default:
        throw StateError('Unexpected method $method');
    }
    return {'apiVersion': 1, 'result': jsonDecode(jsonEncode(result))};
  }
}

class ProjectionSqlWrites extends QueryInterceptor {
  int count = 0;

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    count++;
    return executor.runDelete(statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    count++;
    return executor.runBatched(statements);
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
  test(
    'rule scopes survive read-write-read and profile deletion cascades',
    () async {
      final host = AuthoringHost();
      final owner = host.profiles.single['id'] as String;
      host.profiles.add(
        const Profile(
          id: 'other',
          label: 'Other',
          autoUpdateDuration: Duration.zero,
        ).toJson(),
      );
      host.collections['rules'] = [
        {
          ...const Rule(id: 1, content: 'global.test').toJson(),
          'profileId': null,
        },
        {
          ...const Rule(id: 2, content: 'local.test').toJson(),
          'profileId': owner,
        },
        {
          ...const Rule(id: 3, content: 'other.test').toJson(),
          'profileId': 'other',
        },
      ];
      host.collections['disabledRules'] = [
        {'profileId': owner, 'ruleId': 1},
        {'profileId': owner, 'ruleId': 2},
      ];
      final client = BackendClient(
        transport: host.invoke,
        events: const Stream.empty(),
      );
      final db = Database.backend(client, executor: NativeDatabase.memory());
      addTearDown(db.close);
      addTearDown(client.detach);
      await client.attach();
      await db.refreshFromGo();
      expect((await db.rulesDao.queryGlobalRules().get()).map((r) => r.id), [
        1,
      ]);
      expect(
        (await db.rulesDao.queryProfileRules(owner).get()).single.profileId,
        owner,
      );
      expect((await db.rulesDao.queryProfileRules('other').get()).single.id, 3);

      // An unrelated edit must serialize every rule with its original scope.
      final profile = (await db.profilesDao.query().get()).first;
      await db.profiles.put(profile.copyWith(label: 'Saved').toCompanion());
      expect(
        (host.collections['rules'] as List).map((r) => (r as Map)['profileId']),
        [null, owner, 'other'],
      );
      await db.refreshFromGo();
      expect((await db.rulesDao.queryGlobalRules().get()).single.id, 1);
      expect((await db.rulesDao.queryProfileRules(owner).get()).single.id, 2);
      expect(await db.rulesDao.queryDisabledRuleIds(owner).get(), [1, 2]);

      await db.deleteProfile(owner);
      expect(host.deletedProfileIds, [owner]);
      expect((host.collections['rules'] as List).map((r) => (r as Map)['id']), [
        1,
        3,
      ]);
      expect(host.collections['disabledRules'], isEmpty);
      await db.refreshFromGo();
      expect(await db.rulesDao.queryProfileRules(owner).get(), isEmpty);
      expect((await db.rulesDao.queryGlobalRules().get()).single.id, 1);
      expect((await db.rulesDao.queryProfileRules('other').get()).single.id, 3);
    },
  );

  test(
    'runtime notifications skip SQL until catalog or source changes',
    () async {
      final host = AuthoringHost()..revision = 0;
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final reconnects = StreamController<void>.broadcast(sync: true);
      final client = BackendClient(
        transport: host.invoke,
        events: events.stream,
        reconnects: reconnects.stream,
      );
      final sql = ProjectionSqlWrites();
      final db = Database.backend(
        client,
        executor: NativeDatabase.memory().interceptWith(sql),
      );
      addTearDown(db.close);
      addTearDown(client.detach);
      addTearDown(events.close);
      addTearDown(reconnects.close);
      await client.attach();
      var tail = Future<void>.value();
      final subscription = client.changes.listen((_) {
        tail = tail.then((_) => db.refreshFromGo(ifChanged: true));
      });
      addTearDown(subscription.cancel);
      int reads() =>
          host.methods.where((m) => m == 'authoring.snapshot').length;
      await db.refreshFromGo(ifChanged: true);
      final initialWrites = sql.count;
      expect(
        reads(),
        1,
      ); // Revision zero still needs the full startup snapshot.
      for (var i = 0; i < 12; i++) {
        events.add({
          'apiVersion': 1,
          'seq': ++host.sequence,
          'runtime': {'instanceId': host.instance, 'appliedGeneration': 0},
          'catalogRevision': host.revision,
        });
      }
      await tail;
      await client.refresh();
      await tail;
      expect(reads(), 1);
      expect(sql.count, initialWrites);

      host.revision++;
      host.sequence++;
      host.profiles.single['label'] = 'Catalog changed';
      await client.refresh();
      await tail;
      expect(reads(), 2);
      expect(
        (await db.profilesDao.query().get()).single.label,
        'Catalog changed',
      );

      // A reconnect can replace storage without changing the visible revision.
      host.profiles.single['label'] = 'Reconnected';
      final reconnected = client.changes.first;
      reconnects.add(null);
      await reconnected;
      await tail;
      expect(reads(), 3);
      expect((await db.profilesDao.query().get()).single.label, 'Reconnected');
      host
        ..instance = 'new-go'
        ..sequence = 0;
      host.profiles.single['label'] = 'Restarted';
      await client.refresh();
      await tail;
      expect(reads(), 4);
      expect((await db.profilesDao.query().get()).single.label, 'Restarted');
    },
  );

  test('direct read-backs share cursor and CAS conflicts cannot mark drafts current', () async {
    final host = AuthoringHost();
    final client = BackendClient(
      transport: host.invoke,
      events: const Stream.empty(),
    );
    final db = Database.backend(client, executor: NativeDatabase.memory());
    addTearDown(db.close);
    addTearDown(client.detach);
    await client.attach();
    await db.refreshFromGo();
    int reads() => host.methods.where((m) => m == 'authoring.snapshot').length;
    host.revision++;
    host.sequence++;
    host.profiles.single['label'] = 'Independent write';
    await db.refreshFromGo(); // Authoring read arrives before client catalog.
    await client.refresh();
    await db.refreshFromGo(ifChanged: true);
    expect(reads(), 2);
    final profile = (await db.profilesDao.query().get()).single;
    await db.profiles.put(profile.copyWith(label: 'Own write').toCompanion());
    expect(reads(), 3);
    await db.refreshFromGo(ifChanged: true);
    expect(reads(), 3);
    expect((await db.profilesDao.query().get()).single.label, 'Own write');

    host.revision++;
    host.sequence++;
    host.profiles.single['label'] = 'Racing write';
    await expectLater(
      db.profiles.put(profile.copyWith(label: 'Stale draft').toCompanion()),
      throwsA(
        isA<BackendException>().having(
          (e) => e.isRevisionConflict,
          'conflict',
          isTrue,
        ),
      ),
    );
    await db.refreshFromGo(ifChanged: true);
    expect(reads(), 4);
    expect((await db.profilesDao.query().get()).single.label, 'Racing write');
  });

  test(
    'failed snapshots and resets during a read invalidate revision equality',
    () async {
      final host = AuthoringHost();
      final reconnects = StreamController<void>.broadcast(sync: true);
      final client = BackendClient(
        transport: host.invoke,
        events: const Stream.empty(),
        reconnects: reconnects.stream,
      );
      final db = Database.backend(client, executor: NativeDatabase.memory());
      addTearDown(db.close);
      addTearDown(client.detach);
      addTearDown(reconnects.close);
      await client.attach();
      await db.refreshFromGo();
      host.failSnapshot = true;
      await expectLater(db.refreshFromGo(), throwsA(isA<BackendException>()));
      host.failSnapshot = false;
      host.profiles.single['label'] = 'Retry';
      await db.refreshFromGo(ifChanged: true);
      expect((await db.profilesDao.query().get()).single.label, 'Retry');

      host.beforeAuthoringSnapshot = () async {
        host.beforeAuthoringSnapshot = null;
        final reconnected = client.changes.first;
        reconnects.add(null);
        await reconnected;
      };
      await db.refreshFromGo();
      host.profiles.single['label'] = 'After reset';
      await db.refreshFromGo(ifChanged: true);
      expect((await db.profilesDao.query().get()).single.label, 'After reset');
    },
  );

  test(
    'upload cleanup failure preserves committed read-back and CAS error',
    () async {
      final host = AuthoringHost()..failCleanup = true;
      final client = BackendClient(
        transport: host.invoke,
        events: const Stream.empty(),
      );
      final db = Database.backend(client, executor: NativeDatabase.memory());
      addTearDown(db.close);
      addTearDown(client.detach);
      await client.attach();
      await db.refreshFromGo();
      final script = Script(
        id: 7,
        label: 'Large',
        lastUpdateTime: DateTime.utc(2026),
        source: 'x' * (129 * 1024),
      );
      await db.scripts.put(script.toCompanion());
      expect(host.revision, 2);
      expect((await db.scriptsDao.query().get()).single.source, script.source);
      expect(db.authoringRevision, 2);
      host.conflict = true;
      await expectLater(
        db.scripts.put(script.copyWith(label: 'Rejected').toCompanion()),
        throwsA(
          isA<BackendException>().having(
            (e) => e.isRevisionConflict,
            'conflict',
            isTrue,
          ),
        ),
      );
      expect((await db.scriptsDao.query().get()).single.label, 'Large');
      expect(host.methods.where((m) => m == 'blob.delete'), hasLength(2));
    },
  );
}
