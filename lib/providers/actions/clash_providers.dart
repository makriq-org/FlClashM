part of '../action.dart';

@Riverpod(keepAlive: true)
class ClashProvidersAction extends _$ClashProvidersAction {
  @override
  void build() {}


  Future<ClashProvider> putProvider(
    ClashProvider provider, {
    ClashProvider? previous,
    List<int>? content,
    bool refresh = false,
  }) async {
    if(content!=null) provider=provider.copyWith(contentBase64:base64Encode(content));
    await database.clashProviders.put(provider.toCompanion());
    if(provider.isRemote && (refresh || provider.url!=previous?.url)) {
      await backendClient.command('authoring.resource.update',{'collection':'clashProviders','id':provider.id});
      await database.refreshFromGo();
    }
    return provider;
  }
  Future<ClashProvider?> remoteProviderOf(ExternalProvider external) async {
    final rows=await database.clashProvidersDao.query().get();
    return rows.where((p)=>p.label==external.name).firstOrNull;
  }
  Future<bool> syncRemote(ClashProvider provider) async {
    await backendClient.command('authoring.resource.update',{'collection':'clashProviders','id':provider.id});
    return true;
  }
  Future<ClashProvider> prepare(ClashProvider provider) async => provider;
  void delProvider(ClashProvider provider) { ref.read(clashProvidersProvider.notifier).del(provider.id); }

  Future<List<Profile>> profilesUsing(ClashProvider provider) {
    return profilesReferencing(ProviderKind.rule, provider.label);
  }

  Future<List<Profile>> profilesReferencing(
    ProviderKind kind,
    String name,
  ) async {
    final ids = switch (kind) {
      ProviderKind.proxy => await database.proxyGroupsDao.profileIdsUsing(name),
      ProviderKind.rule => await database.rulesDao.profileIdsUsingRuleProvider(
        name,
      ),
    };
    return [
      for (final profile in ref.read(profilesProvider))
        if (ids.contains(profile.id) ||
            kind == ProviderKind.rule &&
                profile.type == ProfileType.custom &&
                profile.overrides.ruleSets.contains(name))
          profile,
    ];
  }

  Future<bool> _isReferenced(
    String profileId,
    ProviderKind kind,
    Set<String> labels,
  ) async {
    return switch (kind) {
      ProviderKind.proxy =>
        (await database.proxyGroupsDao.query(profileId).get()).any(
          (group) => group.use?.any(labels.contains) ?? false,
        ),
      ProviderKind.rule =>
        (ref
                    .read(profilesProvider)
                    .getProfile(profileId)
                    ?.overrides
                    .ruleSets
                    .any(labels.contains) ??
                false) ||
            (await database.rulesDao.queryProfileRules(profileId).get()).any(
              (rule) => rule.ruleSets.any(labels.contains),
            ),
    };
  }

  /// [force] reapplies a provider whose content changed under the same path,
  /// which leaves the generated config unchanged.
  Future<void> applyIfReferenced(
    ProviderKind kind,
    Set<String> labels, {
    bool force = false,
  }) => _applyIf(
    (profileId) => _isReferenced(profileId, kind, labels),
    force: force,
  );

  Future<void> applyIfProxiesNamed(Set<String> names) => _applyIf(
    (profileId) async => (await database.proxyGroupsDao.query(profileId).get())
        .any((group) => group.proxies?.any(names.contains) ?? false),
  );

  Future<void> _applyIf(
    Future<bool> Function(String profileId) isReferenced, {
    bool force = false,
  }) async {
    final profile = ref.read(currentProfileProvider);
    if (profile == null ||
        profile.type != ProfileType.custom ||
        !await isReferenced(profile.id)) {
      return;
    }
    ref
        .read(setupActionProvider.notifier)
        .applyProfileDebounce(silence: true, force: force);
  }
}
