import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import '../product/backend/backend.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

part 'clash_providers.dart';
part 'converter.dart';
part 'custom_proxies.dart';
part 'dialers.dart';
part 'generated/database.g.dart';
part 'groups.dart';
part 'icons.dart';
part 'profiles.dart';
part 'rules.dart';
part 'scripts.dart';
part 'projection.dart';

@DriftDatabase(
  tables: [
    Profiles,
    Scripts,
    Rules,
    DisabledRules,
    ProxyGroups,
    IconRecords,
    IconSets,
    ClashProviders,
    CustomProxies,
    ProxyDialers,
  ],
  daos: [
    ProfilesDao,
    ScriptsDao,
    RulesDao,
    ProxyGroupsDao,
    IconRecordsDao,
    IconSetsDao,
    ClashProvidersDao,
    CustomProxiesDao,
    ProxyDialersDao,
  ],
)
/// Ephemeral query projection. Go is the only durable authoring store.
class Database extends _$Database {
  factory Database([QueryExecutor? executor]) {
    if(executor!=null)return Database._(executor,null,null);
    return Database.backend(backendClient);
  }
  factory Database.backend(BackendClient client,{QueryExecutor? executor}) {
    final writes=ProjectionWrites();
    final db=Database._((executor??NativeDatabase.memory()).interceptWith(writes),writes,client);
    writes.database=db;
    return db;
  }
  Database._(super.executor,this.writes,this.client);
  final BackendClient? client;
  final projectionZone=Zone.current;
  List<String> projectedProfileIds=[];
  final ProjectionWrites? writes;
  int authoringRevision = 0;
  bool get projecting => Zone.current[_projectionZone] == this;
  @override
  int get schemaVersion => 22;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) => customStatement('PRAGMA foreign_keys = ON'),
  );

  Future<void> restore(
    List<Profile> profiles,
    List<Script> scripts,
    List<Rule> rules,
    List<DisabledRule> disabledRules,
    List<ProxyGroup> proxyGroups, {
    List<ClashProvider> clashProviders = const [],
    List<CustomProxy> customProxies = const [],
    List<ProxyDialer> proxyDialers = const [],
    bool isOverride = false,
  }) async {
    if (profiles.isEmpty &&
        scripts.isEmpty &&
        rules.isEmpty &&
        disabledRules.isEmpty &&
        proxyGroups.isEmpty &&
        clashProviders.isEmpty &&
        customProxies.isEmpty &&
        proxyDialers.isEmpty) {
      return;
    }
    await transaction(() async {
      // Backups taken while foreign keys were off may carry orphaned rows.
      await customStatement('PRAGMA defer_foreign_keys = ON');
      await batch((b) {
        if (isOverride) {
          profilesDao.setAllWithBatch(b, profiles);
          scriptsDao.setAllWithBatch(b, scripts);
          rulesDao.setAllWithBatch(b, rules, disabledRules);
          proxyGroupsDao.setAllWithBatch(b, proxyGroups);
          customProxiesDao.setAllWithBatch(b, customProxies);
          clashProvidersDao.setAllWithBatch(b, clashProviders);
          // Rewriting profiles or custom proxies cascades into these.
          proxyDialersDao.setAllWithBatch(b, proxyDialers);
          return;
        }
        profilesDao.putAllWithBatch(
          b,
          profiles.map((item) => item.toCompanion()),
        );
        scriptsDao.putAllWithBatch(b, scripts);
        rulesDao.putAllWithBatch(b, rules, disabledRules);
        proxyGroupsDao.putAllWithBatch(b, proxyGroups);
        customProxiesDao.putAllWithBatch(b, customProxies);
        clashProvidersDao.putAllWithBatch(b, clashProviders);
        proxyDialersDao.putAllWithBatch(b, proxyDialers);
      });
      await _purgeOrphans();
    });
  }

  Future<void> deleteProfile(String profileId) {
    return profiles.remove((t) => t.id.equals(profileId));
  }

  Future<void> _purgeOrphans() async {
    final profileIds = selectOnly(profiles)..addColumns([profiles.id]);
    final ruleIds = selectOnly(rules)..addColumns([rules.id]);
    final customProxyIds = selectOnly(customProxies)
      ..addColumns([customProxies.id]);
    await rules.remove(
      (t) => t.profileId.isNotNull() & t.profileId.isNotInQuery(profileIds),
    );
    await disabledRules.remove(
      (t) =>
          t.profileId.isNotInQuery(profileIds) | t.ruleId.isNotInQuery(ruleIds),
    );
    await proxyGroups.remove((t) => t.profileId.isNotInQuery(profileIds));
    await proxyDialers.remove(
      (t) =>
          t.profileId.isNotInQuery(profileIds) |
          t.proxyId.isNotInQuery(customProxyIds),
    );
  }
}

// SQLite builds before 3.32 cap a statement at 999 bound parameters.
const _maxBoundValues = 900;

extension TableInfoExt<Tbl extends Table, Row> on TableInfo<Tbl, Row> {
  void setAll(
    Batch batch,
    Iterable<Insertable<Row>> items, {
    required Expression<bool> Function(Tbl tbl) deleteFilter,
    bool preDelete = false,
  }) async {
    if (preDelete) {
      batch.deleteWhere(this, deleteFilter);
    }
    batch.insertAllOnConflictUpdate(this, items);
    if (!preDelete) {
      batch.deleteWhere(this, deleteFilter);
    }
  }

  void deleteInChunks<V extends Object>(
    Batch batch,
    Iterable<V> values,
    Expression<bool> Function(Tbl tbl, List<V> chunk) filter,
  ) {
    for (final chunk in values.chunks(_maxBoundValues)) {
      batch.deleteWhere(this, (tbl) => filter(tbl, chunk));
    }
  }

  Selectable<int?> get count {
    final countExp = countAll();
    final query = select().addColumns([countExp]);
    return query.map((row) => row.read(countExp));
  }

  /// [select] that skips a row this version cannot read instead of failing the
  /// whole query; the row itself stays in the table.
  Selectable<R> readable<R extends Object>(
    R Function(Row row) read, {
    Expression<bool> Function(Tbl tbl)? where,
    List<OrderingTerm Function(Tbl tbl)> orderBy = const [],
  }) {
    final query = selectOnly()..addColumns($columns);
    if (where != null) {
      query.where(where(asDslTable));
    }
    query.orderBy([for (final term in orderBy) term(asDslTable)]);
    return _NonNullSelectable(
      query.map((row) => _readRow(row.rawData.data, read)),
    );
  }

  R? _readRow<R extends Object>(
    Map<String, Object?> data,
    R Function(Row row) read,
  ) {
    try {
      return read(map(data, tablePrefix: aliasedName) as Row);
    } catch (error) {
      commonPrint.log(
        'Skipped unreadable $actualTableName row: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<int> remove(Expression<bool> Function(Tbl tbl) filter) async {
    return (delete()..where(filter)).go();
  }

  Future<int> put(Insertable<Row> item) async {
    return insertOnConflictUpdate(item);
  }
}

class _NonNullSelectable<T extends Object> extends Selectable<T> {
  _NonNullSelectable(this._source);

  final Selectable<T?> _source;

  @override
  Future<List<T>> get() async => (await _source.get()).nonNulls.toList();

  @override
  Stream<List<T>> watch() =>
      _source.watch().map((rows) => rows.nonNulls.toList());
}

extension SimpleSelectStatementExt<T extends HasResultSet, D>
    on SimpleSelectStatement<T, D> {
  Selectable<int> get count {
    final countExp = countAll();
    final query = addColumns([countExp]);
    return query.map((row) => row.read(countExp)!);
  }
}

extension JoinedSelectStatementExt<T extends HasResultSet, D>
    on JoinedSelectStatement<T, D> {
  Selectable<int> get count {
    final countExp = countAll();
    addColumns([countExp]);
    return map((row) => row.read(countExp)!);
  }
}

Database _database = Database();

Database get database => _database;

@visibleForTesting
set database(Database value) => _database = value;
