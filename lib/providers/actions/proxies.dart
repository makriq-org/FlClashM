part of '../action.dart';

class _DelayTestTarget {
  const _DelayTestTarget({
    required this.proxyName,
    required this.testUrl,
    required this.key,
    required this.stamp,
  });

  final String proxyName;
  final String testUrl;
  final String key;
  final ExternalNodeStamp stamp;
}

typedef _DelayTestBatch = ({List<Proxy> proxies, String? testUrl});

class _DelayTestJob {
  _DelayTestJob(List<_DelayTestTarget> targets, this.timeout)
    : held = targets.map((target) => target.key).toSet(),
      proxyNames = {for (final target in targets) target.key: target.proxyName};

  final Duration timeout;
  final Set<String> held;
  final Map<String, String> proxyNames;
  final Set<String> started = {};
  bool cancelled = false;
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final TaskPool _delayTestPool = TaskPool(maxConcurrentDelayTests);

  final List<_DelayTestJob> _delayTestJobs = [];

  final List<({Delay delay, ExternalNodeStamp stamp})> _bufferedDelays = [];

  final List<String> _bufferedStarts = [];

  final List<String> _bufferedFinishes = [];

  Timer? _delayFlushTimer;

  final Map<String, String> _pendingSelectedRollback = {};

  @override
  void build() {
    ref.onDispose(() => _delayFlushTimer?.cancel());
    ref.listen(externalNodesProvider, (previous, next) {
      if (previous == null) return;
      if (previous.scope != next.scope) cancelDelayTests();
      final changed = <String>{
        for (final name in {...previous.nodes.keys, ...next.nodes.keys})
          if (previous.stamp(name) != next.stamp(name)) name,
      };
      _invalidateNodeDelayTests(changed);
      ref.read(delayDataSourceProvider.notifier).removeProxies(changed);
      // Refresh awake nodes after a wake, identity change or plan resync.
      // A selection can advance the plan generation while waking a node;
      // reissue its measurement if that commit cancelled the earlier one.
      final woken = [
        for (final name in changed)
          if (next.nodes[name]?.awake == true &&
              next.nodes[name]?.starting == false &&
              !next.sleeping(name))
            Proxy(name: name, type: 'Socks5'),
      ];
      if (woken.isNotEmpty) {
        final names = woken.map((proxy) => proxy.name).toSet();
        unawaited(
          _runDelayTests([
            (proxies: woken, testUrl: null),
            for (final group in ref.read(groupsProvider))
              (
                proxies: group.all
                    .where((proxy) => names.contains(proxy.name))
                    .toList(),
                testUrl: group.testUrl,
              ),
          ]),
        );
      }
    });
    ref.listen(currentProfileIdProvider, (_, _) => cancelDelayTests());
    ref.listen(
      appSettingProvider.select(
        (state) => (state.testUrl, state.delayTestTimeout),
      ),
      (_, _) => cancelDelayTests(),
    );
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        cancelDelayTests();
      }
    });
  }

  void _invalidateNodeDelayTests(Set<String> names) {
    if (names.isEmpty) return;
    // Settle buffered starts/finishes before releasing this cycle's holds.
    // Delay values are filtered against the new snapshot by the flush itself.
    _flushDelayResults();
    final started = <String>[];
    final queued = <String>[];
    for (final job in _delayTestJobs) {
      final stale = job.held
          .where((key) => names.contains(job.proxyNames[key]))
          .toList();
      for (final key in stale) {
        job.held.remove(key);
        (job.started.contains(key) ? started : queued).add(key);
      }
    }
    ref
        .read(pendingDelayTestsProvider.notifier)
        .apply(finished: started, released: queued);
  }

  void cancelDelayTests() {
    for (final job in _delayTestJobs) {
      job.cancelled = true;
      job.held.clear();
    }
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    _bufferedDelays.clear();
    _bufferedStarts.clear();
    _bufferedFinishes.clear();
    ref.read(pendingDelayTestsProvider.notifier).clear();
  }

  void _scheduleDelayFlush() {
    _delayFlushTimer ??= Timer(renderThrottleDuration, _flushDelayResults);
  }

  void _flushDelayResults() {
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    if (_bufferedDelays.isNotEmpty) {
      final nodes = ref.read(externalNodesProvider);
      final delays = [
        for (final result in _bufferedDelays)
          if (nodes.accepts(result.delay.name, result.stamp)) result.delay,
      ];
      _bufferedDelays.clear();
      ref.read(delayDataSourceProvider.notifier).setDelays(delays);
    }
    if (_bufferedStarts.isNotEmpty || _bufferedFinishes.isNotEmpty) {
      final started = List.of(_bufferedStarts);
      final finished = List.of(_bufferedFinishes);
      _bufferedStarts.clear();
      _bufferedFinishes.clear();
      ref
          .read(pendingDelayTestsProvider.notifier)
          .apply(started: started, finished: finished);
    }
  }

  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    _pendingSelectedRollback.putIfAbsent(
      groupName,
      () => _currentSelectedName(groupName),
    );
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    debouncer.call((FunctionTag.changeProxy, groupName), (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(groupName: groupName, proxyName: proxyName);
      updateGroupsDebounce();
    }, args: [groupName, proxyName]);
  }

  String _currentSelectedName(String groupName) {
    return ref.read(currentProfileProvider)?.selectedMap[groupName] ?? '';
  }

  Future<void> updateGroups() async {
    try {
      ref.read(groupsProvider.notifier).value = await retry(
        task: () async {
          final sortType = ref.read(
            proxiesStyleSettingProvider.select((state) => state.sortType),
          );
          final delayMap = ref.read(delayDataSourceProvider);
          final testUrl = ref.read(
            appSettingProvider.select((state) => state.testUrl),
          );
          final selectedMap = ref.read(
            currentProfileProvider.select((state) => state?.selectedMap ?? {}),
          );
          try {
            return await _core.getProxiesGroups(
              selectedMap: selectedMap,
              sortType: sortType,
              delayMap: delayMap,
              defaultTestUrl: testUrl,
            );
          } catch (e) {
            commonPrint.log(
              'updateGroups error: $e',
              logLevel: coreFailureLogLevel(e),
            );
            return [];
          }
        },
        retryIf: (res) => res.isEmpty,
      );
    } catch (e) {
      // The Core failure path already runs inside the retry task above; a
      // throw here only means ref.read hit a disposed container or the
      // groupsProvider write itself failed.
      commonPrint.log(
        'updateGroups failed: $e',
        logLevel: coreFailureLogLevel(e),
      );
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setShownGroupsUnfolded(bool unfold) {
    final shown = ref
        .read(proxiesListStateProvider)
        .groups
        .map((group) => group.name);
    final current = ref.read(unfoldSetProvider);
    updateCurrentUnfoldSet(
      unfold ? {...current, ...shown} : current.difference(shown.toSet()),
    );
  }

  void setDelay(Delay delay, [ExternalNodeStamp? stamp]) {
    final nodes = ref.read(externalNodesProvider);
    final epoch = stamp ?? nodes.stamp(delay.name);
    if (!nodes.accepts(delay.name, epoch)) return;
    _bufferedDelays.add((delay: delay, stamp: epoch));
    _scheduleDelayFlush();
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    final rollbackName =
        _pendingSelectedRollback.remove(groupName) ??
        _currentSelectedName(groupName);
    profilesAction.updateCurrentSelectedMap(groupName, proxyName);
    final ChangeProxyResult result;
    try {
      result = await _core.changeProxy(
        ChangeProxyParams(groupName: groupName, proxyName: proxyName),
      );
      if (result.message.isNotEmpty) {
        throw MessageException(result.message);
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      profilesAction.updateCurrentSelectedMap(groupName, rollbackName);
      dialogs.showNotifier(
        currentAppLocalizations.changeProxyFailedTip,
        level: MessageLevel.error,
      );
      return;
    }
    if (!result.changed) {
      return;
    }
    try {
      if (ref.read(appSettingProvider).closeConnections) {
        await _core.closeConnections();
      } else {
        await _core.resetConnections();
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) connection reset failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  Future<String> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final clashProvidersAction = ref.read(
        clashProvidersActionProvider.notifier,
      );
      final ruleSet = await clashProvidersAction.remoteProviderOf(provider);
      if (ruleSet != null && !await clashProvidersAction.syncRemote(ruleSet)) {
        return '';
      }
      final message = await _core.updateExternalProvider(
        providerName: provider.name,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<String> sideLoadExternalProvider(
    ExternalProvider provider,
    String data, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final message = await _core.sideLoadExternalProvider(
        providerName: provider.name,
        data: data,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> addToLocalProxies(String name) async {
    await backendClient.command('authoring.copyProxy', {'name': name});
    dialogs.showNotifier(currentAppLocalizations.addedToLocalProxies(name));
  }

  Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) {
    return _runDelayTests([
      (proxies: [proxy], testUrl: testUrl),
    ]);
  }

  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    await _runDelayTests([(proxies: proxies, testUrl: testUrl)]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestGroups(List<Group> groups) async {
    await _runDelayTests([
      for (final group in groups) (proxies: group.all, testUrl: group.testUrl),
    ]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestPageGroup(
    String groupName, {
    bool matchSearch = true,
  }) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null) {
      return;
    }
    final testing = ref.read(delayTestingGroupsProvider.notifier);
    if (!testing.start(groupName)) {
      return;
    }
    try {
      final query = SearchQuery(
        matchSearch ? ref.read(queryProvider(QueryTag.proxies)) : '',
      );
      await delayTest(
        group.all.whereMatches(query, (proxy) => proxy.searchFields).toList(),
        group.testUrl,
      );
    } finally {
      testing.stop(groupName);
    }
  }

  /// A node in several groups is tested once: targets are keyed by node and URL.
  Future<void> delayTestAllGroups() async {
    final testing = ref.read(delayTestingGroupsProvider.notifier);
    final groups = [
      for (final group in ref.read(visibleGroupsStateProvider).value)
        if (testing.start(group.name)) group,
    ];
    if (groups.isEmpty) {
      return;
    }
    try {
      await delayTestGroups(groups);
    } finally {
      for (final group in groups) {
        testing.stop(group.name);
      }
    }
  }

  List<_DelayTestTarget> _resolveDelayTestTargets(
    List<_DelayTestBatch> batches,
  ) {
    final groups = ref.read(groupsProvider);
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final nodes = ref.read(externalNodesProvider);
    final seen = <String>{};
    final targets = <_DelayTestTarget>[];
    for (final batch in batches) {
      final fallbackTestUrl = ref.read(realTestUrlProvider(batch.testUrl));
      for (final proxy in batch.proxies) {
        final state = computeRealSelectedProxyState(
          proxy.name,
          groups: groups,
          selectedMap: selectedMap,
        );
        if (state.proxyName.isEmpty || nodes.sleeping(state.proxyName)) {
          continue;
        }
        final currentTestUrl = state.testUrl.takeFirstValid([fallbackTestUrl]);
        final key = delayTestKey(currentTestUrl, state.proxyName);
        if (!seen.add(key)) {
          continue;
        }
        targets.add(
          _DelayTestTarget(
            proxyName: state.proxyName,
            testUrl: currentTestUrl,
            key: key,
            stamp: nodes.stamp(state.proxyName),
          ),
        );
      }
    }
    return targets;
  }

  Future<void> _runDelayTests(List<_DelayTestBatch> batches) async {
    final targets = _resolveDelayTestTargets(batches);
    if (targets.isEmpty) {
      return;
    }
    final pending = ref.read(pendingDelayTestsProvider.notifier);
    final job = _DelayTestJob(
      targets,
      Duration(
        milliseconds: ref
            .read(appSettingProvider)
            .delayTestTimeout
            .clamp(1000, 60000),
      ),
    );
    _delayTestJobs.add(job);
    // TaskPool.run starts a task synchronously while it has an idle slot.
    job.started.addAll(
      targets.take(_delayTestPool.idleSlots).map((target) => target.key),
    );
    pending.apply(acquired: job.held, started: job.started);
    try {
      await Future.wait(
        targets.map(
          (target) => _delayTestPool.run(() => _runDelayTest(job, target)),
        ),
      );
    } finally {
      _delayTestJobs.remove(job);
      _flushDelayResults();
      final abandoned = job.held.toList();
      job.held.clear();
      pending.apply(
        finished: abandoned.where(job.started.contains),
        released: abandoned.where((key) => !job.started.contains(key)),
      );
    }
  }

  Future<void> _runDelayTest(_DelayTestJob job, _DelayTestTarget target) async {
    if (job.cancelled ||
        !job.held.contains(target.key) ||
        !ref
            .read(externalNodesProvider)
            .accepts(target.proxyName, target.stamp)) {
      if (job.held.remove(target.key)) {
        ref
            .read(pendingDelayTestsProvider.notifier)
            .apply(
              finished: job.started.contains(target.key) ? [target.key] : [],
              released: job.started.contains(target.key) ? [] : [target.key],
            );
      }
      return;
    }
    if (job.started.add(target.key)) {
      _bufferedStarts.add(target.key);
      _scheduleDelayFlush();
    }
    try {
      final delay = await _core.getDelay(
        target.testUrl,
        target.proxyName,
        job.timeout,
      );
      if (delay != null && !job.cancelled) {
        setDelay(delay, target.stamp);
      }
    } catch (error) {
      if (error is CoreMethodException && error.isCoreUnavailable) {
        job.cancelled = true;
      }
      commonPrint.log(
        'Delay test failed for ${target.proxyName}: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      if (job.held.remove(target.key)) {
        _bufferedFinishes.add(target.key);
        _scheduleDelayFlush();
      }
    }
  }
}
