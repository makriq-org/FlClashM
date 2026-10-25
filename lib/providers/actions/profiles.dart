part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  final _importSources = Map<CustomProfileImport,Uint8List>.identity();
  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  Future<void> deleteProfile(String id) async {
    await ref.read(profilesProvider.notifier).del(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
      }
    }
  }

  Future<String> validateConfigWithData(String data) async {
    return _core.validateConfigWithData(data);
  }

  static const expiryNoticeDays = [3, 2, 1, 0];

  /// 3, 2, 1 and 0 days before the end and once it has passed, each said once
  /// per expiry date, in a dialog that can lead to renewal.
  Future<void> noticeSubscriptionExpiry(Profile profile) async {
    final expire = profile.subscriptionInfo?.expire ?? 0;
    if (expire == 0) {
      return;
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
    final left = expiresAt.difference(DateTime.now());
    final threshold = left.isNegative ? -1 : left.inDays;
    if (threshold > expiryNoticeDays.first) {
      return;
    }
    final key = '${profile.id}:$threshold';
    final notices = ref.read(appSettingProvider).subscriptionNotices;
    if (notices[key] == expire) {
      return;
    }
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            subscriptionNotices: {
              for (final entry in state.subscriptionNotices.entries)
                if (entry.key.startsWith('${profile.id}:') &&
                    entry.value == expire)
                  entry.key: entry.value,
              key: expire,
            },
          ),
        );
    await _showExpiry(profile, threshold);
  }

  Future<void> noticeSubscriptionExpiries() async {
    for (final profile in ref.read(profilesProvider)) {
      await noticeSubscriptionExpiry(profile);
    }
  }

  Future<void> _showExpiry(Profile profile, int threshold) async {
    final appLocalizations = currentAppLocalizations;
    final headers = profile.headers;
    final renewUrl = headers.buyPlan?.url ?? headers.supportUrl;
    final message = threshold < 0
        ? appLocalizations.subscriptionExpired
        : threshold == 0
        ? appLocalizations.subscriptionExpiresToday
        : appLocalizations.subscriptionExpiresInDays(threshold);
    final label = headers.serviceName ?? profile.label;
    final title = label.isEmpty
        ? appLocalizations.subscriptionExpiresSoon
        : label;
    final shown = await notificationPort?.show(
      title: title,
      body: message,
      channelName: appLocalizations.subscriptionExpiresSoon,
      url: renewUrl,
    );
    if (shown == true) {
      return;
    }
    final renew = await dialogs.showMessage(
      title: title,
      message: TextSpan(text: message),
      cancelable: renewUrl != null,
      cancelText: appLocalizations.confirm,
      confirmText: renewUrl != null
          ? appLocalizations.renew
          : appLocalizations.confirm,
    );
    if (renew == true && renewUrl != null) {
      await dialogs.openUrl(renewUrl);
    }
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<List<Profile>> providerUsers(Profile profile) async {
    if (profile.type == ProfileType.custom) {
      return const [];
    }
    final users = await ref
        .read(clashProvidersActionProvider.notifier)
        .profilesReferencing(ProviderKind.proxy, profile.realLabel);
    return [
      for (final user in users)
        if (user.id != profile.id) user,
    ];
  }

  /// Where a profile's own group takes a name, the name stands for that group.
  Future<List<Profile>> proxyUsers(Set<String> names) async {
    final (ruleTargets, dialerTargets) = await (
      database.rulesDao.targetsNaming(names),
      database.proxyDialersDao.targetsNaming(names),
    ).wait;
    final users = <Profile>[];
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type != ProfileType.custom) {
        continue;
      }
      final groups = await database.proxyGroupsDao.query(profile.id).get();
      final inUse = proxyNamesInUse(
        names.difference({for (final group in groups) group.name}),
        groups: groups,
        ruleTargets: ruleTargets[profile.id] ?? const {},
        dialerTargets: dialerTargets[profile.id] ?? const {},
        overrides: profile.overrides,
      );
      if (inUse.isNotEmpty) {
        users.add(profile);
      }
    }
    return users;
  }

  Future<Set<String>> groupsInUse(String profileId, Set<int> groupIds) async {
    final groups = await database.proxyGroupsDao.query(profileId).get();
    final names = {
      for (final group in groups)
        if (groupIds.contains(group.id)) group.name,
    };
    final (ruleTargets, dialerTargets) = await (
      database.rulesDao.targetsNaming(names),
      database.proxyDialersDao.targetsNaming(names),
    ).wait;
    return proxyNamesInUse(
      names,
      groups: groups.where((group) => !groupIds.contains(group.id)),
      ruleTargets: ruleTargets[profileId] ?? const {},
      dialerTargets: dialerTargets[profileId] ?? const {},
      overrides:
          ref.read(profilesProvider).getProfile(profileId)?.overrides ??
          const ProfileOverrides(),
    );
  }

  Future<void> updateProfiles() async {
    for (final id in [
      for (final profile in ref.read(profilesProvider)) profile.id,
    ]) {
      final profile = ref.read(profilesProvider).getProfile(id);
      if (profile == null || profile.type != ProfileType.url) continue;
      await updateProfile(profile, showLoading: true);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    try {
      await database.profiles.put(profile.toCompanion());
      final updated=await profile.update(validate:(path,key)=>_core.validateProfile(path,key));
      noticeDeviceHeaders(updated,before:profile,manual:showLoading);
      unawaited(noticeSubscriptionExpiry(updated));
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () => _withAgeSecretKey(
        Profile.normal(label: platformFile.name),
        (profile) => profile.saveFile(
          bytes,
          validate: (path, key) => _core.validateProfile(path, key),
        ),
      ),
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<String> addCustomProfile(String label) async {
    final profile=Profile.custom(label:label);
    await database.profiles.put(profile.toCompanion());
    return profile.id;
  }

  void touchProfile(String id) {
    final profile = ref.read(profilesProvider).getProfile(id);
    if (profile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(lastUpdateDate: DateTime.now()));
  }

  Future<CustomProfileImport> readCustomImport(
    String profileId,
    Uint8List bytes,
  ) async {
    final profiles = ref.read(profilesProvider);
    final (ruleProviders, proxies, groupNames) = await (
      database.clashProvidersDao.query().get(),
      database.customProxiesDao.query().get(),
      database.proxyGroupsDao.names(except: profileId).get(),
    ).wait;
    final CustomImportApp app = (
      profileLabels: {
        for (final profile in profiles) ...[profile.label, profile.realLabel],
      },
      profileSources: {
        for (final profile in profiles)
          if (profile.type == ProfileType.url)
            (url: profile.url, ageSecretKey: profile.ageSecretKey):
                profile.realLabel,
      },
      ruleProviderLabels: {
        for (final provider in ruleProviders) provider.label,
      },
      ruleProviderSources: {
        for (final provider in ruleProviders)
          if (provider.isRemote)
            (url: provider.url, ageSecretKey: ''): provider.label,
      },
      proxies: [for (final proxy in proxies) proxy.definition],
      groupNames: groupNames.toSet(),
    );
    try {
      final preview=await compute(readCustomProfileImport,(bytes:bytes,app:app));
      _importSources.clear();
      _importSources[preview]=bytes;
      return preview;
    } on CustomImportException catch (error) {
      final appLocalizations = currentAppLocalizations;
      throw MessageException(switch (error.issue) {
        CustomImportIssue.unreadable => appLocalizations.importConfigInvalid,
        CustomImportIssue.ruleType => appLocalizations.failedItem(
          error.item,
          appLocalizations.ruleTextInvalid,
        ),
        CustomImportIssue.entry => appLocalizations.failedItem(
          error.item,
          error.detail,
        ),
      });
    }
  }

  /// [config] replaces what [profileId] holds. The providers it adds are saved
  /// before the groups and rules naming them, and loaded afterwards; the
  /// future completes once they have loaded.
  Future<void> importCustomProfile(String profileId,CustomProfileImport config) async {
    final bytes=_importSources.remove(config);
    if(bytes==null)throw StateError('The import preview has expired; reopen the source');
    final snapshot=await backendClient.request('authoring.snapshot') as Map;
    final token=await backendClient.upload(bytes);
    try {
      await backendClient.command('authoring.import',{'expectedRevision':snapshot['revision'],'profileId':profileId,'token':token,'replace':true});
      await database.refreshFromGo();
    } finally { await backendClient.request('blob.delete',{'token':token}); }
  }

  void _showProfiles() {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
  }

  Future<void> addProfileFromLink(
    String link, {
    String? label,
    String ageSecretKey = '',
    bool sendDeviceHeaders = true,
  }) async {
    _showProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () => link.isShareLink
          ? _fromShareLinks(Profile.normal(label: label), [link])
          : _withAgeSecretKey(
              Profile.normal(
                label: label,
                url: link,
                sendDeviceHeaders: sendDeviceHeaders,
              ).copyWith(ageSecretKey: ageSecretKey),
              _download,
            ),
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
      noticeDeviceHeaders(profile, manual: true);
    }
  }

  /// A refusal the panel put in its headers: told on a manual download,
  /// otherwise only once, when an answer first carries it.
  void noticeDeviceHeaders(
    Profile profile, {
    Profile? before,
    required bool manual,
  }) {
    final headers = profile.headers;
    final earlier = before?.headers;
    final appLocalizations = currentAppLocalizations;
    if (headers.deviceLimitReached &&
        (manual || earlier?.deviceLimitReached != true)) {
      unawaited(
        _showPanelRefusal(
          headers,
          title: appLocalizations.deviceLimitReached,
          message:
              headers.fullAnnouncement ?? appLocalizations.deviceLimitReached,
        ),
      );
      return;
    }
    if (headers.deviceIdUnsupported &&
        (manual || earlier?.deviceIdUnsupported != true)) {
      unawaited(
        _showPanelRefusal(
          headers,
          title: appLocalizations.deviceIdUnsupportedTitle,
          message: profile.sendDeviceHeaders
              ? appLocalizations.deviceIdUnsupported
              : appLocalizations.deviceIdNotSent,
        ),
      );
    }
  }

  Future<void> _showPanelRefusal(
    ProviderHeaders headers, {
    required String title,
    required String message,
  }) async {
    final appLocalizations = currentAppLocalizations;
    final supportUrl = headers.supportUrl;
    final toSupport = await dialogs.showMessage(
      title: title,
      message: TextSpan(text: message),
      cancelable: supportUrl != null,
      cancelText: appLocalizations.confirm,
      confirmText: supportUrl != null
          ? appLocalizations.support
          : appLocalizations.confirm,
    );
    if (toSupport == true && supportUrl != null) {
      await dialogs.openUrl(supportUrl);
    }
  }

  /// Ids are taken up front so the list keeps the order of [links]; the share
  /// links among them make up one profile, in the place of the first.
  Future<void> addProfilesFromLinks(List<String> links) async {
    _showProfiles();
    final shareLinks = [
      for (final link in links)
        if (link.isShareLink) link,
    ];
    await globalState.batchRun(
      [
        for (final link in links)
          if (!link.isShareLink)
            (profile: Profile.normal(url: link), shareLinks: const <String>[])
          else if (link == shareLinks.first)
            (profile: Profile.normal(), shareLinks: shareLinks),
      ],
      (item) async => putProfile(
        await (item.shareLinks.isEmpty
            ? _download(item.profile)
            : _fromShareLinks(item.profile, item.shareLinks)),
      ),
      label: (item) => item.shareLinks.firstOrNull ?? item.profile.url,
      concurrency: maxConcurrentImports,
      tag: LoadingTag.profiles,
    );
  }

  Future<Profile> _download(Profile profile) {
    return profile.update(
      validate: (path, key) => _core.validateProfile(path, key),
    );
  }

  Future<Profile> _withAgeSecretKey(
    Profile profile,
    Future<Profile> Function(Profile profile) save,
  ) async {
    try {
      return await save(profile);
    } on AgeSecretKeyRequiredException {
      final key = (await dialogs.showAgeSecretKeyInput())?.trim();
      if (key == null || key.isEmpty) {
        rethrow;
      }
      return save(profile.copyWith(ageSecretKey: key));
    }
  }

  Future<Profile> _fromShareLinks(Profile profile, List<String> links) async {
    final appLocalizations = currentAppLocalizations;
    final decoded = await _core.decodeShareLinks(links);
    final taken = {...reservedCustomProxyNames};
    final proxies = <Map<String, dynamic>>[];
    for (final (index, definitions) in decoded.indexed) {
      if (definitions.isEmpty) {
        throw MessageException(
          links.length == 1
              ? appLocalizations.shareLinksInvalid
              : appLocalizations.shareLinkUnreadable(links[index]),
        );
      }
      for (final definition in definitions) {
        final name = freeProxyName(linkProxyName(definition), taken);
        proxies.add({...definition, 'name': name});
      }
    }
    final first = proxies.first['name'] as String;
    final label = proxies.length == 1
        ? first
        : appLocalizations.proxiesProfileLabel(first, proxies.length);
    final config = await encodeYamlTask({'proxies': proxies});
    return profile
        .copyWith(label: profile.label.takeFirstValid([label]))
        .saveFile(
          utf8.encode(config),
          validate: (path, _) => _core.validateConfig(path),
        );
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFromLink(url));
  }

  Future<void> clearEffect(String profileId) async {
    try {
      final error = await _core.clearEffect(profileId);
      if (error.isNotEmpty) {
        commonPrint.log(error, logLevel: LogLevel.warning);
      }
    } catch (error) {
      commonPrint.log(
        'clearEffect($profileId) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }
}
