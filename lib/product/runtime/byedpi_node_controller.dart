import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashm/common/common.dart';
import 'package:flclashm/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'byedpi_release.dart';

typedef ByedpiWaitForRuntimeNodeListenerCallback = Future<void> Function(
  String host,
  int port,
);

typedef ByedpiSiteCheckCallback = Future<bool> Function({
  required String host,
  required int port,
  required Uri url,
  required Duration timeout,
});

typedef ByedpiProbePortAllocator = Future<int> Function();

@immutable
class ByedpiSharedInstallLayout {
  const ByedpiSharedInstallLayout({
    required this.abi,
    required this.runtimeRootPath,
    required this.nodesDirectoryPath,
    required this.executablePath,
    required this.pendingPath,
    required this.rollbackPath,
    required this.versionPath,
    required this.pendingVersionPath,
    required this.bundledAssetPath,
    this.managedBinaryUpdateEnabled = true,
  });

  final String abi;
  final String runtimeRootPath;
  final String nodesDirectoryPath;
  final String executablePath;
  final String pendingPath;
  final String rollbackPath;
  final String versionPath;
  final String pendingVersionPath;
  final String bundledAssetPath;
  final bool managedBinaryUpdateEnabled;
}

@immutable
class ByedpiNodeLayout {
  const ByedpiNodeLayout({
    required this.nodeId,
    required this.workingDirectoryPath,
    required this.configPath,
    required this.cachePath,
  });

  final String nodeId;
  final String workingDirectoryPath;
  final String configPath;
  final String cachePath;
}

abstract interface class ByedpiBinaryBridge {
  String get bundledReleaseTag;

  Future<ByedpiSharedInstallLayout> resolveSharedInstallLayout();

  Future<Uint8List> loadBundledBinary(String assetPath);

  Future<String> loadBundledStrategyList(String assetPath);
}

class DefaultByedpiBinaryBridge implements ByedpiBinaryBridge {
  const DefaultByedpiBinaryBridge({
    this.nativeLibrary = const AndroidRuntimeNodeNativeLibraryBridge(),
  });

  final AndroidRuntimeNodeNativeLibraryBridge nativeLibrary;

  @override
  String get bundledReleaseTag => byedpiPinnedReleaseTag;

  @override
  Future<ByedpiSharedInstallLayout> resolveSharedInstallLayout() async {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    ByedpiReleaseAsset? asset;
    for (final abi in deviceInfo.supportedAbis) {
      final candidate = byedpiReleaseAssets[abi];
      if (candidate != null) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      throw UnsupportedError(
        'byedpi is not packaged for Android ABIs: '
        '${deviceInfo.supportedAbis.join(', ')}',
      );
    }

    final homeDir = await appPath.homeDirPath;
    final runtimeRootPath = path.join(
      homeDir,
      'runtimes',
      byedpiRuntimeDirectoryName,
      asset.abi,
    );
    final executablePath = await nativeLibrary.resolvePath(
      byedpiAndroidNativeLibraryFileName,
    );
    if (executablePath == null) {
      throw StateError(
        'Bundled native byedpi library $byedpiAndroidNativeLibraryFileName '
        'is missing. Run `dart setup.dart android --out runtime-assets` '
        'before building.',
      );
    }

    return ByedpiSharedInstallLayout(
      abi: asset.abi,
      runtimeRootPath: runtimeRootPath,
      nodesDirectoryPath: path.join(runtimeRootPath, 'nodes'),
      executablePath: executablePath,
      pendingPath: path.join(
        runtimeRootPath,
        '$byedpiExecutableFileName.pending',
      ),
      rollbackPath: path.join(
        runtimeRootPath,
        '$byedpiExecutableFileName.rollback',
      ),
      versionPath: path.join(runtimeRootPath, byedpiBundledVersionFileName),
      pendingVersionPath: path.join(
        runtimeRootPath,
        byedpiPendingVersionFileName,
      ),
      bundledAssetPath: asset.bundledAssetPath,
      managedBinaryUpdateEnabled: false,
    );
  }

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List();
  }

  @override
  Future<String> loadBundledStrategyList(String assetPath) async =>
      rootBundle.loadString(assetPath);
}

@immutable
class _ByedpiNodeMutation {
  const _ByedpiNodeMutation({
    required this.plan,
    required this.previousPlan,
    required this.layout,
    required this.previousConfig,
    required this.wasRunning,
  });

  final BuiltInProxyNodePlan plan;
  final BuiltInProxyNodePlan? previousPlan;
  final ByedpiNodeLayout layout;
  final String? previousConfig;
  final bool wasRunning;
}

@immutable
class _ByedpiStageState {
  const _ByedpiStageState({
    required this.mutations,
    required this.removedPlans,
  });

  final List<_ByedpiNodeMutation> mutations;
  final List<BuiltInProxyNodePlan> removedPlans;
}

@immutable
class _ByedpiConfig {
  const _ByedpiConfig({
    required this.mode,
    required this.listenHost,
    required this.listenPort,
    required this.args,
    required this.strategies,
    required this.strategyList,
    required this.testUrls,
    required this.testSni,
    required this.timeout,
    required this.requests,
    required this.concurrency,
    required this.minSuccessRatio,
    required this.cacheTtl,
    required this.recheckAfter,
    required this.failureThreshold,
  });

  final String mode;
  final String listenHost;
  final int listenPort;
  final String args;
  final List<String> strategies;
  final String strategyList;
  final List<Uri> testUrls;
  final String testSni;
  final Duration timeout;
  final int requests;
  final int concurrency;
  final double minSuccessRatio;
  final Duration cacheTtl;
  final Duration recheckAfter;
  final int failureThreshold;

  bool get isAuto => mode == 'auto';

  _ByedpiConfig copyWith({
    int? listenPort,
  }) =>
      _ByedpiConfig(
        mode: mode,
        listenHost: listenHost,
        listenPort: listenPort ?? this.listenPort,
        args: args,
        strategies: strategies,
        strategyList: strategyList,
        testUrls: testUrls,
        testSni: testSni,
        timeout: timeout,
        requests: requests,
        concurrency: concurrency,
        minSuccessRatio: minSuccessRatio,
        cacheTtl: cacheTtl,
        recheckAfter: recheckAfter,
        failureThreshold: failureThreshold,
      );
}

@immutable
class _ByedpiStrategyCache {
  const _ByedpiStrategyCache({
    required this.fingerprint,
    required this.strategy,
    required this.checkedAt,
    required this.failures,
  });

  final String fingerprint;
  final String strategy;
  final DateTime checkedAt;
  final int failures;

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'strategy': strategy,
        'checkedAt': checkedAt.toIso8601String(),
        'failures': failures,
      };

  static _ByedpiStrategyCache? fromJson(String content) {
    final value = json.decode(content);
    if (value is! Map) {
      return null;
    }
    final strategy = value['strategy'];
    final fingerprint = value['fingerprint'];
    final checkedAt = DateTime.tryParse('${value['checkedAt']}');
    if (strategy is! String || fingerprint is! String || checkedAt == null) {
      return null;
    }
    return _ByedpiStrategyCache(
      fingerprint: fingerprint,
      strategy: strategy,
      checkedAt: checkedAt,
      failures: (value['failures'] as num?)?.toInt() ?? 0,
    );
  }
}

class ByedpiNodeController {
  ByedpiNodeController({
    this.binary = const DefaultByedpiBinaryBridge(),
    this.runtime = const AndroidRuntimeNodeBridge(),
    this.waitForListener = _waitForRuntimeNodeListener,
    this.siteCheck = _checkUrlViaSocks,
    this.allocateProbePort = _allocateLoopbackPort,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final ByedpiBinaryBridge binary;
  final RuntimeNodePlatformBridge runtime;
  final ByedpiWaitForRuntimeNodeListenerCallback waitForListener;
  final ByedpiSiteCheckCallback siteCheck;
  final ByedpiProbePortAllocator allocateProbePort;
  final DateTime Function() now;

  _ByedpiStageState? _stagedState;

  Future<void> applyPendingUpdate() async {
    final layout = await binary.resolveSharedInstallLayout();
    await Directory(layout.runtimeRootPath).create(recursive: true);
    await Directory(layout.nodesDirectoryPath).create(recursive: true);
    if (!layout.managedBinaryUpdateEnabled) {
      return;
    }

    final active = File(layout.executablePath);
    final pending = File(layout.pendingPath);
    final rollback = File(layout.rollbackPath);
    final versionFile = File(layout.versionPath);
    final pendingVersionFile = File(layout.pendingVersionPath);

    if (pendingVersionFile.existsSync() && !pending.existsSync()) {
      await _deleteWithRetry(pendingVersionFile);
    }

    if (!active.existsSync() && !pending.existsSync()) {
      await _writeBundledBinary(layout, active);
      await _writeVersionFile(versionFile, binary.bundledReleaseTag);
      return;
    }

    final installedBundledTag = await _readVersionFile(versionFile);
    if (installedBundledTag != binary.bundledReleaseTag &&
        !pending.existsSync()) {
      await _writeBundledBinary(layout, pending);
      await _writeVersionFile(pendingVersionFile, binary.bundledReleaseTag);
    }

    if (!pending.existsSync()) {
      return;
    }

    final pendingBundledTag = await _readVersionFile(pendingVersionFile);
    try {
      await _deleteWithRetry(rollback);
      if (active.existsSync()) {
        await _renameWithRetry(active, rollback.path);
      }
      await _renameWithRetry(pending, active.path);
      if (pendingBundledTag != null) {
        await _writeVersionFile(versionFile, pendingBundledTag);
        await _deleteWithRetry(pendingVersionFile);
      }
      await _deleteWithRetry(rollback);
    } catch (_) {
      if (rollback.existsSync()) {
        await _deleteWithRetry(active);
        await _renameWithRetry(rollback, active.path);
      }
      rethrow;
    }
  }

  Future<String> stageRuntimePlan({
    required List<BuiltInProxyNodePlan> currentPlans,
    required List<BuiltInProxyNodePlan> nextPlans,
  }) async {
    if (_stagedState != null) {
      return 'byedpi runtime plan stage is already active.';
    }

    final sharedLayout = await binary.resolveSharedInstallLayout();
    await Directory(sharedLayout.runtimeRootPath).create(recursive: true);
    await Directory(sharedLayout.nodesDirectoryPath).create(recursive: true);

    final currentById = {for (final plan in currentPlans) plan.nodeId: plan};
    final nextById = {for (final plan in nextPlans) plan.nodeId: plan};
    final mutations = <_ByedpiNodeMutation>[];

    try {
      for (final plan in nextPlans) {
        final layout = _resolveNodeLayout(sharedLayout, plan.nodeId);
        final configJson = _readConfigArtifact(plan);
        final configFile = File(layout.configPath);
        final previousConfig =
            configFile.existsSync() ? await configFile.readAsString() : null;
        final wasRunning =
            await runtime.readNodeStartTime(nodeId: plan.nodeId) != null;
        final previousPlan = currentById[plan.nodeId];

        final configChanged = previousConfig != configJson;
        final isNewPlan = previousPlan == null;
        if (!isNewPlan && !configChanged) {
          continue;
        }

        mutations.add(
          _ByedpiNodeMutation(
            plan: plan,
            previousPlan: previousPlan,
            layout: layout,
            previousConfig: previousConfig,
            wasRunning: wasRunning,
          ),
        );

        await Directory(layout.workingDirectoryPath).create(recursive: true);
        await configFile.writeAsString(configJson, flush: true);

        if (wasRunning) {
          await runtime.stopNode(nodeId: plan.nodeId);
          final started = await _startPlan(sharedLayout, plan);
          if (!started) {
            return _rollbackStageFailure(
              mutations: mutations,
              failureMessage:
                  'byedpi node `${plan.name}` failed to restart after config update.',
            );
          }
        }
      }
    } catch (e) {
      return _rollbackStageFailure(
        mutations: mutations,
        failureMessage: 'byedpi runtime plan staging failed: $e',
      );
    }

    _stagedState = _ByedpiStageState(
      mutations: mutations,
      removedPlans: [
        for (final plan in currentPlans)
          if (!nextById.containsKey(plan.nodeId)) plan,
      ],
    );
    return '';
  }

  Future<String> rollbackStagedRuntimePlan() async {
    final stagedState = _stagedState;
    if (stagedState == null) {
      return '';
    }
    final message = await _rollbackStageFailure(
      mutations: stagedState.mutations,
      failureMessage: 'byedpi runtime plan rollback failed.',
    );
    _stagedState = null;
    return message == 'byedpi runtime plan rollback failed.' ? '' : message;
  }

  Future<void> commitStagedRuntimePlan() async {
    final stagedState = _stagedState;
    if (stagedState == null) {
      return;
    }
    _stagedState = null;

    for (final removedPlan in stagedState.removedPlans) {
      await runtime.stopNode(nodeId: removedPlan.nodeId);
      final sharedLayout = await binary.resolveSharedInstallLayout();
      final layout = _resolveNodeLayout(sharedLayout, removedPlan.nodeId);
      await _deleteDirectoryIfExists(Directory(layout.workingDirectoryPath));
    }
  }

  Future<bool> startNodes(List<BuiltInProxyNodePlan> plans) async {
    if (plans.isEmpty) {
      return true;
    }
    final sharedLayout = await binary.resolveSharedInstallLayout();
    final startedNodes = <BuiltInProxyNodePlan>[];
    try {
      for (final plan in plans) {
        final alreadyRunning =
            await runtime.readNodeStartTime(nodeId: plan.nodeId) != null;
        if (!alreadyRunning) {
          final started = await _startPlan(sharedLayout, plan);
          if (!started) {
            await _stopStartedNodes(startedNodes);
            return false;
          }
          startedNodes.add(plan);
        }
        await waitForListener(plan.listenHost, plan.listenPort);
      }
      return true;
    } catch (e, stackTrace) {
      await _stopStartedNodes(startedNodes);
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  Future<void> stopNodes(List<BuiltInProxyNodePlan> plans) async {
    Object? error;
    StackTrace? stackTrace;
    for (final plan in plans) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e, s) {
        error ??= e;
        stackTrace ??= s;
      }
    }
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  Future<List<Map<String, dynamic>>> buildColdStartNodes(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    if (plans.isEmpty) {
      return const [];
    }
    final sharedLayout = await binary.resolveSharedInstallLayout();
    final nodes = <Map<String, dynamic>>[];
    for (final plan in plans) {
      final layout = _resolveNodeLayout(sharedLayout, plan.nodeId);
      final arguments = await _resolveColdStartArguments(plan, layout);
      if (arguments == null) {
        continue;
      }
      nodes.add(
        <String, dynamic>{
          'nodeId': plan.nodeId,
          'type': plan.type.label,
          'name': plan.name,
          'host': plan.listenHost,
          'port': plan.listenPort,
          'executablePath': sharedLayout.executablePath,
          'workingDirectory': layout.workingDirectoryPath,
          'arguments': arguments,
        },
      );
    }
    return nodes;
  }

  Future<void> persistColdStart(List<BuiltInProxyNodePlan> plans) async {
    final nodes = await buildColdStartNodes(plans);
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
      return;
    }
    await saveColdStartNodes(nodes);
  }

  Future<void> saveColdStartNodes(List<Map<String, dynamic>> nodes) async {
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
      return;
    }
    await runtime.saveColdStartNodes(json.encode({'nodes': nodes}));
  }

  Future<bool> _startPlan(
    ByedpiSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
  ) async {
    final layout = _resolveNodeLayout(sharedLayout, plan.nodeId);
    final config = await _readNodeConfig(plan, layout);
    if (config.isAuto) {
      return _startAutoPlan(sharedLayout, plan, layout, config);
    }
    final arguments = _buildArguments(config.args, config);
    final started = await runtime.startNode(
      nodeId: plan.nodeId,
      executablePath: sharedLayout.executablePath,
      workingDirectory: layout.workingDirectoryPath,
      arguments: arguments,
    );
    if (!started) {
      return false;
    }
    await waitForListener(plan.listenHost, plan.listenPort);
    return true;
  }

  Future<bool> _startAutoPlan(
    ByedpiSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    ByedpiNodeLayout layout,
    _ByedpiConfig config,
  ) async {
    final strategies = await _resolveStrategies(config);
    final fingerprint = _fingerprint(
      strategies: strategies,
      config: config,
      releaseTag: sharedLayout.abi + binary.bundledReleaseTag,
    );
    final cached = await _readCache(layout);
    if (_canUseCache(cached, fingerprint, config)) {
      if (!_needsRecheck(cached!, config)) {
        return _startWithStrategy(sharedLayout, plan, config, cached.strategy);
      }
      final started = await _startWithStrategy(
        sharedLayout,
        plan,
        config,
        cached.strategy,
      );
      if (!started) {
        return false;
      }
      final passed = await _checkStrategy(cached.strategy, config);
      if (passed) {
        await _writeCache(
          layout,
          _ByedpiStrategyCache(
            fingerprint: fingerprint,
            strategy: cached.strategy,
            checkedAt: now(),
            failures: 0,
          ),
        );
        return true;
      }
      await runtime.stopNode(nodeId: plan.nodeId);
      final failures = cached.failures + 1;
      if (failures < config.failureThreshold) {
        await _writeCache(
          layout,
          _ByedpiStrategyCache(
            fingerprint: fingerprint,
            strategy: cached.strategy,
            checkedAt: cached.checkedAt,
            failures: failures,
          ),
        );
        return _startWithStrategy(sharedLayout, plan, config, cached.strategy);
      }
    }

    final selected = await _selectStrategy(
      sharedLayout,
      plan,
      config,
      strategies,
    );
    if (selected != null) {
      await _writeCache(
        layout,
        _ByedpiStrategyCache(
          fingerprint: fingerprint,
          strategy: selected,
          checkedAt: now(),
          failures: 0,
        ),
      );
      return _startWithStrategy(sharedLayout, plan, config, selected);
    }

    if (cached != null && cached.fingerprint == fingerprint) {
      commonPrint.log(
        'byedpi node `${plan.name}` did not find a new strategy; using cached strategy.',
      );
      return _startWithStrategy(sharedLayout, plan, config, cached.strategy);
    }

    throw StateError('byedpi node `${plan.name}` could not select strategy.');
  }

  Future<List<String>?> _resolveColdStartArguments(
    BuiltInProxyNodePlan plan,
    ByedpiNodeLayout layout,
  ) async {
    final config = await _readNodeConfig(plan, layout);
    if (!config.isAuto) {
      return _buildArguments(config.args, config);
    }
    final cached = await _readCache(layout);
    if (cached == null) {
      return null;
    }
    return _buildArguments(cached.strategy, config);
  }

  Future<String?> _selectStrategy(
    ByedpiSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    _ByedpiConfig config,
    List<String> strategies,
  ) async {
    for (final strategy in strategies) {
      final probePort = await allocateProbePort();
      final probeConfig = config.copyWith(listenPort: probePort);
      final probeNodeId = '${plan.nodeId}-probe-${strategy.toMd5()}';
      final started = await _startWithStrategy(
        sharedLayout,
        plan,
        probeConfig,
        strategy,
        nodeId: probeNodeId,
      );
      if (!started) {
        continue;
      }
      try {
        final passed = await _checkStrategy(strategy, probeConfig);
        if (passed) {
          return strategy;
        }
      } finally {
        await runtime.stopNode(nodeId: probeNodeId);
      }
    }
    return null;
  }

  Future<bool> _startWithStrategy(
    ByedpiSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    _ByedpiConfig config,
    String strategy, {
    String? nodeId,
  }) async {
    final layout = _resolveNodeLayout(sharedLayout, plan.nodeId);
    final started = await runtime.startNode(
      nodeId: nodeId ?? plan.nodeId,
      executablePath: sharedLayout.executablePath,
      workingDirectory: layout.workingDirectoryPath,
      arguments: _buildArguments(strategy, config),
    );
    if (!started) {
      return false;
    }
    await waitForListener(config.listenHost, config.listenPort);
    return true;
  }

  Future<bool> _checkStrategy(String strategy, _ByedpiConfig config) async {
    final checks = <Uri>[
      for (final url in config.testUrls)
        for (var i = 0; i < config.requests; i++) url,
    ];
    if (checks.isEmpty) {
      return false;
    }

    var success = 0;
    var nextCheck = 0;
    final requestedConcurrency =
        config.concurrency < 1 ? 1 : config.concurrency;
    final workerCount = requestedConcurrency < checks.length
        ? requestedConcurrency
        : checks.length;

    Future<void> worker() async {
      while (true) {
        final index = nextCheck++;
        if (index >= checks.length) {
          return;
        }
        final url = checks[index];
        if (await siteCheck(
          host: config.listenHost,
          port: config.listenPort,
          url: url,
          timeout: config.timeout,
        )) {
          success++;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < workerCount; i++) worker(),
    ]);
    return success / checks.length >= config.minSuccessRatio;
  }

  bool _canUseCache(
    _ByedpiStrategyCache? cached,
    String fingerprint,
    _ByedpiConfig config,
  ) {
    if (cached == null || cached.fingerprint != fingerprint) {
      return false;
    }
    return now().difference(cached.checkedAt) <= config.cacheTtl;
  }

  bool _needsRecheck(_ByedpiStrategyCache cached, _ByedpiConfig config) =>
      now().difference(cached.checkedAt) >= config.recheckAfter;

  List<String> _buildArguments(String strategy, _ByedpiConfig config) => [
        '--ip',
        config.listenHost,
        '--port',
        config.listenPort.toString(),
        ..._splitShell(strategy.replaceAll('{sni}', config.testSni)),
      ];

  Future<List<String>> _resolveStrategies(_ByedpiConfig config) async {
    if (config.strategies.isNotEmpty) {
      return config.strategies;
    }
    if (config.strategyList != 'byebyeedpi') {
      return const [];
    }
    final content = await binary.loadBundledStrategyList(
      byedpiStrategyListAssetPath,
    );
    return content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList(growable: false);
  }

  Future<_ByedpiConfig> _readNodeConfig(
    BuiltInProxyNodePlan plan,
    ByedpiNodeLayout layout,
  ) async {
    final file = File(layout.configPath);
    final content = file.existsSync()
        ? await file.readAsString()
        : _readConfigArtifact(plan);
    final value = json.decode(content);
    if (value is! Map) {
      throw StateError('byedpi node `${plan.name}` config is not an object.');
    }
    final test = _asMap(value['test']);
    final cache = _asMap(value['cache']);
    final urls = [
      for (final item in (test['urls'] as List? ?? const []))
        if (Uri.tryParse('$item') case final uri?) uri,
    ];
    return _ByedpiConfig(
      mode: '${value['mode'] ?? 'manual'}',
      listenHost: '${value['listenHost']}',
      listenPort: (value['listenPort'] as num).toInt(),
      args: '${value['args'] ?? ''}',
      strategies: [
        for (final item in (value['strategies'] as List? ?? const []))
          if ('$item'.trim().isNotEmpty) '$item'.trim(),
      ],
      strategyList: '${value['strategyList'] ?? ''}',
      testUrls: urls,
      testSni: '${test['sni'] ?? 'google.com'}',
      timeout: Duration(seconds: (test['timeout'] as num?)?.toInt() ?? 5),
      requests: (test['requests'] as num?)?.toInt() ?? 1,
      concurrency: (test['concurrency'] as num?)?.toInt() ?? 4,
      minSuccessRatio: (test['min-success-ratio'] as num?)?.toDouble() ?? 1.0,
      cacheTtl: Duration(
        seconds: (cache['ttl'] as num?)?.toInt() ?? 604800,
      ),
      recheckAfter: Duration(
        seconds: (cache['recheck-after'] as num?)?.toInt() ?? 86400,
      ),
      failureThreshold: (cache['failure-threshold'] as num?)?.toInt() ?? 2,
    );
  }

  String _readConfigArtifact(BuiltInProxyNodePlan plan) {
    final configJson =
        plan.files['built-in-proxies/byedpi/${plan.nodeId}/config.json'];
    if (configJson == null || configJson.isEmpty) {
      throw StateError(
        'byedpi node `${plan.name}` is missing config.json artifact.',
      );
    }
    return configJson;
  }

  ByedpiNodeLayout _resolveNodeLayout(
    ByedpiSharedInstallLayout sharedLayout,
    String nodeId,
  ) {
    final workingDirectoryPath =
        path.join(sharedLayout.nodesDirectoryPath, nodeId);
    return ByedpiNodeLayout(
      nodeId: nodeId,
      workingDirectoryPath: workingDirectoryPath,
      configPath: path.join(workingDirectoryPath, byedpiConfigFileName),
      cachePath: path.join(workingDirectoryPath, 'strategy-cache.json'),
    );
  }

  Future<String> _rollbackStageFailure({
    required List<_ByedpiNodeMutation> mutations,
    required String failureMessage,
  }) async {
    for (final mutation in mutations.reversed) {
      await runtime.stopNode(nodeId: mutation.plan.nodeId);
      final configFile = File(mutation.layout.configPath);
      if (mutation.previousConfig == null) {
        await _deleteWithRetry(configFile);
        await _deleteDirectoryIfExists(
          Directory(mutation.layout.workingDirectoryPath),
        );
      } else {
        await configFile.writeAsString(mutation.previousConfig!, flush: true);
      }
      if (mutation.wasRunning) {
        final sharedLayout = await binary.resolveSharedInstallLayout();
        final rollbackPlan = mutation.previousPlan ?? mutation.plan;
        final restarted = await _startPlan(sharedLayout, rollbackPlan);
        if (!restarted) {
          return '$failureMessage Rollback failed: previous byedpi node did not restart.';
        }
      }
    }
    return failureMessage;
  }

  Future<void> _stopStartedNodes(List<BuiltInProxyNodePlan> plans) async {
    for (final plan in plans.reversed) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e) {
        commonPrint.log(
          'Failed to stop byedpi node `${plan.name}` during start rollback: $e',
        );
      }
    }
  }

  Future<_ByedpiStrategyCache?> _readCache(ByedpiNodeLayout layout) async {
    final file = File(layout.cachePath);
    if (!file.existsSync()) {
      return null;
    }
    return _ByedpiStrategyCache.fromJson(await file.readAsString());
  }

  Future<void> _writeCache(
    ByedpiNodeLayout layout,
    _ByedpiStrategyCache cache,
  ) async {
    await File(layout.cachePath).writeAsString(
      json.encode(cache.toJson()),
      flush: true,
    );
  }

  String _fingerprint({
    required List<String> strategies,
    required _ByedpiConfig config,
    required String releaseTag,
  }) =>
      sha256
          .convert(
            utf8.encode(
              json.encode({
                'release': releaseTag,
                'strategies': strategies,
                'urls': config.testUrls.map((url) => url.toString()).toList(),
                'sni': config.testSni,
                'timeout': config.timeout.inSeconds,
                'requests': config.requests,
                'concurrency': config.concurrency,
                'minSuccessRatio': config.minSuccessRatio,
              }),
            ),
          )
          .toString();

  Map<String, dynamic> _asMap(Object? value) {
    if (value is! Map) {
      return <String, dynamic>{};
    }
    return value.map((key, mapValue) => MapEntry('$key', mapValue));
  }

  List<String> _splitShell(String value) {
    final args = <String>[];
    final buffer = StringBuffer();
    var quote = '';
    var escape = false;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (escape) {
        buffer.write(char);
        escape = false;
        continue;
      }
      if (char == r'\') {
        escape = true;
        continue;
      }
      if (quote.isNotEmpty) {
        if (char == quote) {
          quote = '';
        } else {
          buffer.write(char);
        }
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
        continue;
      }
      if (char.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          args.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }
      buffer.write(char);
    }
    if (buffer.isNotEmpty) {
      args.add(buffer.toString());
    }
    return args;
  }

  Future<void> _writeBundledBinary(
    ByedpiSharedInstallLayout layout,
    File target,
  ) async {
    try {
      final bytes = await binary.loadBundledBinary(layout.bundledAssetPath);
      await target.writeAsBytes(bytes, flush: true);
    } catch (e) {
      throw StateError(
        'Bundled byedpi asset ${layout.bundledAssetPath} is missing. '
        'Run `dart setup.dart android --out runtime-assets` first. $e',
      );
    }
  }

  Future<String?> _readVersionFile(File file) async {
    if (!file.existsSync()) {
      return null;
    }
    final content = (await file.readAsString()).trim();
    return content.isEmpty ? null : content;
  }

  Future<void> _writeVersionFile(File file, String version) =>
      file.writeAsString(version, flush: true);

  Future<void> _deleteWithRetry(File file) async {
    if (!file.existsSync()) {
      return;
    }
    for (var i = 0; i < 10; i++) {
      try {
        await file.delete();
        return;
      } catch (_) {
        if (i == 9) rethrow;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _deleteDirectoryIfExists(Directory directory) async {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _renameWithRetry(File source, String targetPath) async {
    for (var i = 0; i < 10; i++) {
      try {
        await source.rename(targetPath);
        return;
      } catch (_) {
        if (i == 9) rethrow;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  static Future<void> _waitForRuntimeNodeListener(
    String host,
    int port,
  ) async {
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        await socket.close();
        return;
      } catch (_) {
        if (attempt == 49) {
          throw StateError(
            'Timed out waiting for local runtime node listener on $host:$port.',
          );
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  static Future<int> _allocateLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<bool> _checkUrlViaSocks({
    required String host,
    required int port,
    required Uri url,
    required Duration timeout,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      final targetHost = url.host;
      final targetPort =
          url.hasPort ? url.port : (url.scheme == 'http' ? 80 : 443);
      final hostBytes = utf8.encode(targetHost);
      socket.add([
        0x05,
        0x01,
        0x00,
        0x05,
        0x01,
        0x00,
        0x03,
        hostBytes.length,
        ...hostBytes,
        (targetPort >> 8) & 0xff,
        targetPort & 0xff,
      ]);
      await socket.flush();
      final response = await socket
          .timeout(timeout)
          .expand((chunk) => chunk)
          .take(4)
          .toList();
      return response.length == 4 &&
          response[0] == 0x05 &&
          response[1] == 0x00 &&
          response[2] == 0x05 &&
          response[3] == 0x00;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}
