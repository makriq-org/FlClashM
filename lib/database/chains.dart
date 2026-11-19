part of 'database.dart';

@DataClassName('RawProxyChain')
@TableIndex(
  name: 'idx_proxy_chains_profile_order',
  columns: {#profileId, #order},
)
class ProxyChains extends Table {
  @override
  String get tableName => 'proxy_chains';

  IntColumn get id => integer()();

  TextColumn get profileId =>
      text().references(Profiles, #id, onDelete: KeyAction.cascade)();

  TextColumn get name => text()();

  TextColumn get hops => text().map(const StringListConverter())();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  TextColumn get order => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftAccessor(tables: [ProxyChains])
class ProxyChainsDao extends DatabaseAccessor<Database>
    with _$ProxyChainsDaoMixin {
  ProxyChainsDao(super.attachedDatabase);

  Selectable<ProxyChain> query(String profileId) {
    final stmt = proxyChains.select();
    stmt.where((row) => row.profileId.equals(profileId));
    stmt.orderBy([
      (t) => OrderingTerm(expression: t.order, nulls: NullsOrder.last),
      (t) => OrderingTerm.asc(t.id),
    ]);
    return stmt.map((row) => row.toProxyChain());
  }

  Future<void> put(ProxyChain chain, String profileId) async {
    await proxyChains.insertOnConflictUpdate(chain.toCompanion(profileId));
  }

  Future<void> remove(ProxyChain chain) async {
    await (proxyChains.delete()..where((t) => t.id.equals(chain.id))).go();
  }
}

extension RawProxyChainExt on RawProxyChain {
  ProxyChain toProxyChain() {
    return ProxyChain(
      id: id,
      name: name,
      hops: hops,
      enabled: enabled,
      profileId: profileId,
      order: order,
    );
  }
}

extension ProxyChainsCompanionExt on ProxyChain {
  ProxyChainsCompanion toCompanion(String profileId) {
    return ProxyChainsCompanion.insert(
      id: Value(id),
      profileId: profileId,
      name: name,
      hops: hops ?? const [],
      enabled: Value(enabled),
      order: Value(order),
    );
  }
}
