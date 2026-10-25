part of 'database.dart';

final _projectionZone = Object();

/// Every SQL mutation is a UI draft. Go CAS must succeed before SQLite commits.
/// There is no SQLite file, boot recovery, subscription task or runtime owner.
class ProjectionWrites extends QueryInterceptor {
  late Database database;
  QueryExecutorUser? _user;
  final _dirty = <QueryExecutor>{};
  final _roots = <TransactionExecutor>{};

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    _user = user;
    return executor.ensureOpen(user);
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final tx = parent.beginTransaction();
    if (parent is! TransactionExecutor) _roots.add(tx);
    return tx;
  }

  Future<T> _write<T>(
    QueryExecutor executor,
    Future<T> Function(QueryExecutor) run,
  ) async {
    if (database.projecting) return run(executor);
    if (executor is TransactionExecutor) {
      _dirty.add(executor);
      return run(executor);
    }
    final tx = executor.beginTransaction();
    await tx.ensureOpen(_user!);
    try {
      final result = await run(tx);
      await database.persistProjection(tx);
      await tx.send();
      await database.projectionZone.run(database.refreshFromGo);
      return result;
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }

  @override
  Future<int> runInsert(QueryExecutor e, String s, List<Object?> a) =>
      _write(e, (tx) => tx.runInsert(s, a));
  @override
  Future<int> runUpdate(QueryExecutor e, String s, List<Object?> a) =>
      _write(e, (tx) => tx.runUpdate(s, a));
  @override
  Future<int> runDelete(QueryExecutor e, String s, List<Object?> a) =>
      _write(e, (tx) => tx.runDelete(s, a));
  @override
  Future<void> runBatched(QueryExecutor e, BatchedStatements s) =>
      _write(e, (tx) => tx.runBatched(s));
  @override
  Future<void> commitTransaction(TransactionExecutor tx) async {
    final commit =
        _roots.remove(tx) && _dirty.isNotEmpty && !database.projecting;
    if (commit) {
      await database.persistProjection(tx);
      _dirty.clear();
    }
    await tx.send();
    if (commit) await database.projectionZone.run(database.refreshFromGo);
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor tx) async {
    _roots.remove(tx);
    _dirty.remove(tx);
    await tx.rollback();
  }
}

extension BackendProjection on Database {
  Future<void> refreshFromGo() async {
    await runZoned(
      () => transaction(() async {
        final snapshot = Map<String, dynamic>.from(
          await client!.request('authoring.snapshot') as Map,
        );
        final collections = Map<String, dynamic>.from(
          snapshot['collections'] as Map,
        );
        final profiles = (snapshot['profiles'] as List)
            .map((v) => Profile.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList();

        // Delete dependents first; the snapshot is then inserted as one view.
        for (final table in <TableInfo>[
          disabledRules,
          proxyDialers,
          proxyGroups,
          rules,
          clashProviders,
          customProxies,
          scripts,
          iconRecords,
          iconSets,
          this.profiles,
        ]) {
          await delete(table).go();
        }
        await batch((b) {
          b.insertAll(this.profiles, profiles.map((p) => p.toCompanion()));
          b.insertAll(
            scripts,
            _rows(
              collections,
              'scripts',
            ).map((v) => Script.fromJson(v).toCompanion()),
          );
          b.insertAll(
            rules,
            _rows(
              collections,
              'rules',
            ).map((v) => Rule.fromJson(v).toCompanion()),
          );
          b.insertAll(
            disabledRules,
            _rows(
              collections,
              'disabledRules',
            ).map((v) => DisabledRule.fromJson(v).toCompanion()),
          );
          b.insertAll(
            proxyGroups,
            _rows(
              collections,
              'proxyGroups',
            ).map((v) => ProxyGroup.fromJson(v).toCompanion()),
          );
          b.insertAll(
            clashProviders,
            _rows(
              collections,
              'clashProviders',
            ).map((v) => ClashProvider.fromJson(v).toCompanion()),
          );
          b.insertAll(
            customProxies,
            _rows(
              collections,
              'customProxies',
            ).map((v) => CustomProxy.fromJson(v).toCompanion()),
          );
          b.insertAll(
            proxyDialers,
            _rows(
              collections,
              'proxyDialers',
            ).map((v) => ProxyDialer.fromJson(v).toCompanion()),
          );
          b.insertAll(
            iconSets,
            _rows(
              collections,
              'iconSets',
            ).map((v) => IconSet.fromJson(v).toCompanion()),
          );
          b.insertAll(
            iconRecords,
            _rows(collections, 'iconRecords').map(IconRecord.fromJson),
          );
        });
        authoringRevision = (snapshot['revision'] as num).toInt();
        projectedProfileIds = profiles.map((p) => p.id).toList();
      }),
      zoneValues: {_projectionZone: this},
    );
  }

  Future<void> persistProjection(QueryExecutor executor) async {
    Future<List<T>> rows<T>(
      TableInfo table,
      T Function(dynamic row) convert,
    ) async => [
      for (final row in await executor.runSelect(
        'SELECT * FROM "${table.actualTableName}"',
        [],
      ))
        convert(table.map(row)),
    ];
    final nextProfiles = await rows(
      profiles,
      (v) => (v as RawProfile).toProfile().toJson(),
    );
    final collections = <String, dynamic>{
      'scripts': await rows(
        scripts,
        (v) => (v as RawScript).toScript().toJson(),
      ),
      'rules': await rows(rules, (v) => (v as RawRule).toRule().toJson()),
      'disabledRules': await rows(
        disabledRules,
        (v) => (v as RawDisabledRule).toDisabledRule().toJson(),
      ),
      'proxyGroups': await rows(
        proxyGroups,
        (v) => (v as RawProxyGroup).toProxyGroup().toJson(),
      ),
      'clashProviders': await rows(
        clashProviders,
        (v) => (v as RawClashProvider).toClashProvider().toJson(),
      ),
      'customProxies': await rows(
        customProxies,
        (v) => (v as RawCustomProxy).toCustomProxy().toJson(),
      ),
      'proxyDialers': await rows(
        proxyDialers,
        (v) => (v as RawProxyDialer).toProxyDialer().toJson(),
      ),
      'iconRecords': await rows(iconRecords, (v) => (v as IconRecord).toJson()),
      'iconSets': await rows(
        iconSets,
        (v) => (v as RawIconSet).toIconSet().toJson(),
      ),
    };
    final ids = nextProfiles.map((p) => p['id'] as String).toSet();
    final encoded = utf8.encode(json.encode(collections));
    String? token;
    if (encoded.length > 128 * 1024)
      token = await client!.upload(Uint8List.fromList(encoded));
    late Map<String, dynamic> receipt;
    try {
      receipt = await client!.command('authoring.replace', {
        'expectedRevision': authoringRevision,
        if (token == null) 'collections': collections else 'token': token,
        'profiles': nextProfiles,
        'deletedProfileIds': [
          for (final id in projectedProfileIds)
            if (!ids.contains(id)) id,
        ],
      });
    } finally {
      if (token != null) await client!.request('blob.delete', {'token': token});
    }
    authoringRevision = (receipt['revision'] as num).toInt();
    projectedProfileIds = ids.toList();
  }
}

Iterable<Map<String, dynamic>> _rows(
  Map<String, dynamic> collections,
  String key,
) => (collections[key] as List? ?? []).map(
  (v) => Map<String, dynamic>.from(v as Map),
);
