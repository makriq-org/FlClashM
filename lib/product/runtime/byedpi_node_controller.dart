import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'byedpi_release.dart';
import 'local_node_controller.dart';

const _byedpiAutoFallbackStrategy = '--disorder 1 --auto=torst --tlsrec 1+s';
const _defaultByedpiStrategyTestSni = 'google.com';
// Strategy probes must not resolve their test host through the system resolver:
// while mihomo is up its fake-ip DNS answers with a placeholder address that the
// probe cannot dial. Resolution is delegated to this DoH endpoint instead. The
// literal IP host avoids a bootstrap chicken-and-egg (no name to resolve first).
// A node may override it via `strategyTest.resolver`, or set it to `system` to
// fall back to the platform resolver.
const _defaultByedpiProbeResolver = 'https://1.1.1.1/dns-query';
const _byedpiAutoSelectionRevision = 2;
final _byedpiMonotonicClock = Stopwatch()..start();

typedef ByedpiProbePortAllocator = Future<int> Function();

@immutable
class ByedpiSharedInstallLayout extends LocalNodeSharedInstallLayout {
  const ByedpiSharedInstallLayout({
    required super.abi,
    required super.runtimeRootPath,
    required super.nodesDirectoryPath,
    required super.executablePath,
  });
}

@immutable
class ByedpiNodeLayout extends LocalNodeLayout {
  const ByedpiNodeLayout({
    required super.nodeId,
    required super.workingDirectoryPath,
    required super.configPath,
    required this.cachePath,
  });

  final String cachePath;
}

abstract interface class ByedpiBinaryBridge
    extends LocalNodeBinaryBridge<ByedpiSharedInstallLayout> {
  String get bundledReleaseTag;

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
    );
  }

  @override
  Future<String> loadBundledStrategyList(String assetPath) =>
      rootBundle.loadString(assetPath);
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
    required this.resolver,
    required this.timeout,
    required this.requests,
    required this.concurrency,
    required this.minSuccessRatio,
    required this.cacheTtl,
    required this.recheckAfter,
    required this.failureThreshold,
    required this.retryAfter,
    required this.selectionConcurrency,
    required this.foregroundTimeout,
    required this.backgroundSelection,
    required this.fallbackStrategy,
  });

  final String mode;
  final String listenHost;
  final int listenPort;
  final String args;
  final List<String> strategies;
  final String strategyList;
  final List<Uri> testUrls;
  final String testSni;
  final String resolver;
  final Duration timeout;
  final int requests;
  final int concurrency;
  final double minSuccessRatio;
  final Duration cacheTtl;
  final Duration recheckAfter;
  final int failureThreshold;
  final Duration retryAfter;
  final int selectionConcurrency;
  final Duration foregroundTimeout;
  final bool backgroundSelection;
  final String fallbackStrategy;

  bool get isAuto => mode == 'auto';

  _ByedpiConfig withListenPort(int listenPort) => _ByedpiConfig(
        mode: mode,
        listenHost: listenHost,
        listenPort: listenPort,
        args: args,
        strategies: strategies,
        strategyList: strategyList,
        testUrls: testUrls,
        testSni: testSni,
        resolver: resolver,
        timeout: timeout,
        requests: requests,
        concurrency: concurrency,
        minSuccessRatio: minSuccessRatio,
        cacheTtl: cacheTtl,
        recheckAfter: recheckAfter,
        failureThreshold: failureThreshold,
        retryAfter: retryAfter,
        selectionConcurrency: selectionConcurrency,
        foregroundTimeout: foregroundTimeout,
        backgroundSelection: backgroundSelection,
        fallbackStrategy: fallbackStrategy,
      );
}

@immutable
class _ByedpiStrategyCache {
  const _ByedpiStrategyCache({
    required this.fingerprint,
    required this.strategy,
    required this.checkedAt,
    required this.failures,
    required this.selectionRevision,
    required this.verified,
    required this.nextIndex,
  });

  final String fingerprint;
  final String strategy;
  final DateTime checkedAt;
  final int failures;
  final int selectionRevision;
  final bool verified;
  final int nextIndex;

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'strategy': strategy,
        'checkedAt': checkedAt.toIso8601String(),
        'failures': failures,
        'selectionRevision': selectionRevision,
        'verified': verified,
        'nextIndex': nextIndex,
      };

  static _ByedpiStrategyCache? fromJson(String content) {
    final value = json.decode(content);
    if (value is! Map) return null;
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
      selectionRevision: (value['selectionRevision'] as num?)?.toInt() ?? 0,
      verified: value['verified'] == true,
      nextIndex: (value['nextIndex'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class _ByedpiPendingSelection {
  const _ByedpiPendingSelection({
    required this.plan,
    required this.sharedLayout,
    required this.layout,
    required this.config,
    required this.strategies,
    required this.fingerprint,
    required this.nextIndex,
    this.verifiedCache,
  });

  final BuiltInProxyNodePlan plan;
  final ByedpiSharedInstallLayout sharedLayout;
  final ByedpiNodeLayout layout;
  final _ByedpiConfig config;
  final List<String> strategies;
  final String fingerprint;
  final int nextIndex;
  final _ByedpiStrategyCache? verifiedCache;

  _ByedpiPendingSelection copyWith({int? nextIndex}) => _ByedpiPendingSelection(
        plan: plan,
        sharedLayout: sharedLayout,
        layout: layout,
        config: config,
        strategies: strategies,
        fingerprint: fingerprint,
        nextIndex: nextIndex ?? this.nextIndex,
        verifiedCache: verifiedCache,
      );
}

@immutable
class _ByedpiSelectionResult {
  const _ByedpiSelectionResult({
    required this.nextIndex,
    this.strategy,
  });

  final String? strategy;
  final int nextIndex;
}

class ByedpiNodeController
    extends LocalNodeController<ByedpiSharedInstallLayout, ByedpiNodeLayout> {
  ByedpiNodeController({
    ByedpiBinaryBridge binary = const DefaultByedpiBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
    this.allocateProbePort = _allocateLoopbackPort,
    DateTime Function()? now,
    Duration Function()? monotonicNow,
  })  : now = now ?? DateTime.now,
        monotonicNow = monotonicNow ?? _readMonotonicClock,
        super(
          typeLabel: 'byedpi',
          configArtifactName: 'config.json',
          binary: binary,
        );

  final DateTime Function() now;
  final Duration Function() monotonicNow;
  final ByedpiProbePortAllocator allocateProbePort;
  final Map<String, _ByedpiPendingSelection> _pendingSelections = {};
  int _backgroundGeneration = 0;
  Future<void>? _backgroundWorker;

  @override
  ByedpiBinaryBridge get binary => super.binary as ByedpiBinaryBridge;

  @override
  String readConfigArtifact(BuiltInProxyNodePlan plan) {
    final configJson =
        plan.files['built-in-proxies/byedpi/${plan.nodeId}/config.json'];
    if (configJson == null || configJson.isEmpty) {
      throw StateError(
        'byedpi node `${plan.name}` is missing config.json artifact.',
      );
    }
    return configJson;
  }

  @override
  ByedpiNodeLayout resolveNodeLayout(
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

  @override
  Future<LocalNodeLaunchExtras> buildLaunchExtras(
    BuiltInProxyNodePlan plan,
    ByedpiSharedInstallLayout sharedLayout,
    ByedpiNodeLayout layout,
  ) async {
    final config = await _readNodeConfig(plan, layout);
    var strategy = config.args;
    if (config.isAuto) {
      strategy = await _resolveAutoStrategy(
        plan: plan,
        sharedLayout: sharedLayout,
        layout: layout,
        config: config,
      );
    }
    return LocalNodeLaunchExtras(
      fields: {
        'arguments': _buildArguments(strategy, config),
      },
    );
  }

  Future<String> _resolveAutoStrategy({
    required BuiltInProxyNodePlan plan,
    required ByedpiSharedInstallLayout sharedLayout,
    required ByedpiNodeLayout layout,
    required _ByedpiConfig config,
  }) async {
    final strategies = await _resolveStrategies(config);
    final fingerprint = _fingerprint(
      strategies: strategies,
      config: config,
      releaseTag: sharedLayout.abi + binary.bundledReleaseTag,
    );
    final cached = await _readCache(layout);
    final pending = _pendingSelections[plan.nodeId];
    if (pending != null && pending.fingerprint == fingerprint) {
      return cached?.strategy ?? config.fallbackStrategy;
    }

    if (_matchesCurrentCache(cached, fingerprint) &&
        cached!.verified &&
        now().difference(cached.checkedAt) <= config.cacheTtl) {
      if (_needsRecheck(cached, config)) {
        _pendingSelections[plan.nodeId] = _ByedpiPendingSelection(
          plan: plan,
          sharedLayout: sharedLayout,
          layout: layout,
          config: config,
          strategies: strategies,
          fingerprint: fingerprint,
          nextIndex: 0,
          verifiedCache: cached,
        );
      }
      return cached.strategy;
    }

    var startIndex = 0;
    if (_matchesCurrentCache(cached, fingerprint) && !cached!.verified) {
      if (now().difference(cached.checkedAt) < config.retryAfter) {
        return cached.strategy;
      }
      startIndex = cached.nextIndex.clamp(0, strategies.length);
      if (startIndex >= strategies.length) startIndex = 0;
    }

    final selection = await _selectWithinForegroundBudget(
      plan: plan,
      sharedLayout: sharedLayout,
      layout: layout,
      config: config,
      strategies: strategies,
      startIndex: startIndex,
    );
    if (selection.strategy case final strategy?) {
      await _writeCache(
        layout,
        _verifiedCache(
          fingerprint: fingerprint,
          strategy: strategy,
        ),
      );
      _pendingSelections.remove(plan.nodeId);
      return strategy;
    }

    final provisional = _provisionalCache(
      fingerprint: fingerprint,
      strategy: config.fallbackStrategy,
      nextIndex:
          selection.nextIndex >= strategies.length ? 0 : selection.nextIndex,
    );
    await _writeCache(layout, provisional);
    if (config.backgroundSelection && selection.nextIndex < strategies.length) {
      _pendingSelections[plan.nodeId] = _ByedpiPendingSelection(
        plan: plan,
        sharedLayout: sharedLayout,
        layout: layout,
        config: config,
        strategies: strategies,
        fingerprint: fingerprint,
        nextIndex: selection.nextIndex,
      );
    } else {
      _pendingSelections.remove(plan.nodeId);
    }
    commonPrint.log(
      'byedpi node `${plan.name}` did not select a strategy within the '
      'foreground budget; using fallback.',
    );
    return config.fallbackStrategy;
  }

  Future<void> cancelBackgroundSelection({bool clearPending = true}) async {
    _backgroundGeneration++;
    if (clearPending) _pendingSelections.clear();
    final worker = _backgroundWorker;
    await worker;
    if (identical(_backgroundWorker, worker)) _backgroundWorker = null;
  }

  void startBackgroundSelection(
    List<BuiltInProxyNodePlan> plans, {
    required Future<bool> Function() onSelectionChanged,
  }) {
    final planIds = plans.map((plan) => plan.nodeId).toSet();
    final pending = _pendingSelections.values
        .where((selection) => planIds.contains(selection.plan.nodeId))
        .toList(growable: false);
    if (pending.isEmpty) return;
    final generation = ++_backgroundGeneration;
    final previousWorker = _backgroundWorker;
    final worker = () async {
      await previousWorker;
      if (generation != _backgroundGeneration) return;
      await _continueSelections(
        pending,
        generation: generation,
        onSelectionChanged: onSelectionChanged,
      );
    }();
    _backgroundWorker = worker;
    unawaited(worker);
  }

  Future<void> _continueSelections(
    List<_ByedpiPendingSelection> selections, {
    required int generation,
    required Future<bool> Function() onSelectionChanged,
  }) async {
    for (final selection in selections) {
      if (generation != _backgroundGeneration) return;
      await _continueSelection(
        selection,
        generation: generation,
        onSelectionChanged: onSelectionChanged,
      );
    }
  }

  Future<_ByedpiSelectionResult> _selectWithinForegroundBudget({
    required BuiltInProxyNodePlan plan,
    required ByedpiSharedInstallLayout sharedLayout,
    required ByedpiNodeLayout layout,
    required _ByedpiConfig config,
    required List<String> strategies,
    required int startIndex,
  }) async {
    final deadline = monotonicNow() + config.foregroundTimeout;
    var nextIndex = startIndex;
    while (nextIndex < strategies.length) {
      final remaining = deadline - monotonicNow();
      // The native probe timeout is expressed in whole seconds. Starting one
      // with less than a second left would let it overrun the foreground
      // budget by almost a full timeout unit.
      if (remaining < const Duration(seconds: 1)) break;
      final batchEnd = (nextIndex + config.selectionConcurrency).clamp(
        nextIndex,
        strategies.length,
      );
      final batch = strategies.sublist(nextIndex, batchEnd);
      final selected = await _probeStrategies(
        plan: plan,
        sharedLayout: sharedLayout,
        layout: layout,
        config: config,
        strategies: batch,
        maximumDuration: remaining,
      );
      nextIndex = batchEnd;
      if (selected != null) {
        return _ByedpiSelectionResult(
          strategy: selected,
          nextIndex: nextIndex,
        );
      }
    }
    return _ByedpiSelectionResult(nextIndex: nextIndex);
  }

  Future<void> _continueSelection(
    _ByedpiPendingSelection initial, {
    required int generation,
    required Future<bool> Function() onSelectionChanged,
  }) async {
    var pending = initial;
    try {
      final cached = pending.verifiedCache;
      if (cached != null) {
        final selected = await _probeStrategies(
          plan: pending.plan,
          sharedLayout: pending.sharedLayout,
          layout: pending.layout,
          config: pending.config,
          strategies: [cached.strategy],
          maximumDuration: pending.config.timeout,
        );
        if (generation != _backgroundGeneration) return;
        if (selected != null) {
          await _writeCache(
            pending.layout,
            _verifiedCache(
              fingerprint: pending.fingerprint,
              strategy: cached.strategy,
            ),
          );
          if (generation != _backgroundGeneration) return;
          _pendingSelections.remove(pending.plan.nodeId);
          return;
        }
        final failures = cached.failures + 1;
        if (failures < pending.config.failureThreshold) {
          await _writeCache(
            pending.layout,
            _ByedpiStrategyCache(
              fingerprint: cached.fingerprint,
              strategy: cached.strategy,
              checkedAt: cached.checkedAt,
              failures: failures,
              selectionRevision: _byedpiAutoSelectionRevision,
              verified: true,
              nextIndex: 0,
            ),
          );
          if (generation != _backgroundGeneration) return;
          _pendingSelections.remove(pending.plan.nodeId);
          return;
        }
      }

      var nextIndex = pending.nextIndex;
      while (generation == _backgroundGeneration &&
          nextIndex < pending.strategies.length) {
        final batchEnd =
            (nextIndex + pending.config.selectionConcurrency).clamp(
          nextIndex,
          pending.strategies.length,
        );
        final batch = pending.strategies.sublist(nextIndex, batchEnd);
        final selected = await _probeStrategies(
          plan: pending.plan,
          sharedLayout: pending.sharedLayout,
          layout: pending.layout,
          config: pending.config,
          strategies: batch,
          maximumDuration: pending.config.timeout,
        );
        if (generation != _backgroundGeneration) return;
        nextIndex = batchEnd;
        if (selected != null) {
          await _activateSelectionCache(
            pending: pending,
            generation: generation,
            cache: _verifiedCache(
              fingerprint: pending.fingerprint,
              strategy: selected,
            ),
            fallbackNextIndex: nextIndex,
            onSelectionChanged: onSelectionChanged,
          );
          return;
        }
        if (cached == null) {
          final provisional = _provisionalCache(
            fingerprint: pending.fingerprint,
            strategy: pending.config.fallbackStrategy,
            nextIndex: nextIndex >= pending.strategies.length ? 0 : nextIndex,
          );
          await _writeCache(pending.layout, provisional);
          if (generation != _backgroundGeneration) return;
          pending = pending.copyWith(nextIndex: nextIndex);
          _pendingSelections[pending.plan.nodeId] = pending;
        }
      }
      if (cached != null && generation == _backgroundGeneration) {
        await _activateSelectionCache(
          pending: pending,
          generation: generation,
          cache: _provisionalCache(
            fingerprint: pending.fingerprint,
            strategy: pending.config.fallbackStrategy,
            nextIndex: 0,
          ),
          fallbackNextIndex: 0,
          onSelectionChanged: onSelectionChanged,
        );
        return;
      }
      _pendingSelections.remove(pending.plan.nodeId);
    } catch (error) {
      commonPrint.log(
        'byedpi node `${pending.plan.name}` background selection failed: $error',
      );
    }
  }

  Future<void> _activateSelectionCache({
    required _ByedpiPendingSelection pending,
    required int generation,
    required _ByedpiStrategyCache cache,
    required int fallbackNextIndex,
    required Future<bool> Function() onSelectionChanged,
  }) async {
    final previousCache = await _readCache(pending.layout);
    if (generation != _backgroundGeneration) return;
    await _writeCache(pending.layout, cache);
    if (generation != _backgroundGeneration) return;
    _pendingSelections.remove(pending.plan.nodeId);

    var activated = false;
    try {
      activated = await onSelectionChanged();
    } catch (error) {
      commonPrint.log(
        'byedpi node `${pending.plan.name}` could not activate the '
        'background strategy: $error',
      );
    }
    if (activated) return;

    await _restoreCache(
      pending.layout,
      previousCache ??
          _provisionalCache(
            fingerprint: pending.fingerprint,
            strategy: pending.config.fallbackStrategy,
            nextIndex: fallbackNextIndex,
          ),
    );
    if (generation != _backgroundGeneration) return;
    try {
      await onSelectionChanged();
    } catch (error) {
      commonPrint.log(
        'byedpi node `${pending.plan.name}` could not restore the '
        'previous runtime strategy: $error',
      );
    }
  }

  Future<String?> _probeStrategies({
    required BuiltInProxyNodePlan plan,
    required ByedpiSharedInstallLayout sharedLayout,
    required ByedpiNodeLayout layout,
    required _ByedpiConfig config,
    required List<String> strategies,
    required Duration maximumDuration,
  }) async {
    if (strategies.isEmpty || maximumDuration <= Duration.zero) return null;
    final timeoutSeconds = _wholeSeconds(
      maximumDuration < config.timeout ? maximumDuration : config.timeout,
    ).clamp(1, 60);
    final ports = await _allocateDistinctProbePorts(strategies.length);
    final nodes = <Map<String, dynamic>>[
      for (var index = 0; index < strategies.length; index++)
        _buildProbeNode(
          plan: plan,
          sharedLayout: sharedLayout,
          layout: layout,
          config: config.withListenPort(ports[index]),
          strategy: strategies[index],
          timeoutSeconds: timeoutSeconds,
        ),
    ];
    try {
      if (runtime case final RuntimeNodeBatchProbePlatformBridge bridge) {
        final selectedIndex = await bridge.probeNodes(
          nodes,
          concurrency: config.selectionConcurrency,
        );
        if (selectedIndex == null ||
            selectedIndex < 0 ||
            selectedIndex >= strategies.length) {
          return null;
        }
        return strategies[selectedIndex];
      }
      if (runtime case final RuntimeNodeProbePlatformBridge bridge) {
        for (var index = 0; index < nodes.length; index++) {
          if (await bridge.probeNode(nodes[index])) return strategies[index];
        }
      }
    } catch (error) {
      commonPrint.log(
        'byedpi node `${plan.name}` strategy probe failed: $error',
      );
    }
    return null;
  }

  Map<String, dynamic> _buildProbeNode({
    required BuiltInProxyNodePlan plan,
    required ByedpiSharedInstallLayout sharedLayout,
    required ByedpiNodeLayout layout,
    required _ByedpiConfig config,
    required String strategy,
    required int timeoutSeconds,
  }) =>
      <String, dynamic>{
        'nodeId': '${plan.nodeId}-probe-${strategy.toMd5()}',
        'type': plan.type.label,
        'name': '${plan.name} strategy probe',
        'host': config.listenHost,
        'port': config.listenPort,
        'executablePath': sharedLayout.executablePath,
        'workingDirectory': layout.workingDirectoryPath,
        'arguments': _buildArguments(strategy, config),
        'revision': sha256.convert(utf8.encode(strategy)).toString(),
        'connectivityCheck': <String, dynamic>{
          'urls': config.testUrls.map((url) => '$url').toList(),
          'resolver': config.resolver,
          'required': true,
          'timeout': timeoutSeconds,
          'startup-timeout': timeoutSeconds,
          'retry-interval': 1,
          'requests': config.requests,
          'concurrency': config.concurrency,
          'min-success-ratio': config.minSuccessRatio,
        },
      };

  List<String> _buildArguments(String strategy, _ByedpiConfig config) => [
        '--ip',
        config.listenHost,
        '--port',
        config.listenPort.toString(),
        ..._splitShell(strategy.replaceAll('{sni}', config.testSni)),
      ];

  Future<List<String>> _resolveStrategies(_ByedpiConfig config) async {
    final sources = config.strategies.isNotEmpty
        ? config.strategies
        : config.strategyList == 'byebyeedpi'
            ? const ['builtin:byebyeedpi']
            : const <String>[];
    final values = <String>[];
    final seen = <String>{};
    for (final source in sources) {
      final expanded = source == 'builtin:byebyeedpi'
          ? (await binary.loadBundledStrategyList(byedpiStrategyListAssetPath))
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty && !line.startsWith('#'))
          : <String>[source];
      for (final strategy in expanded) {
        if (seen.add(strategy)) values.add(strategy);
      }
    }
    return List<String>.unmodifiable(values);
  }

  Future<_ByedpiConfig> _readNodeConfig(
    BuiltInProxyNodePlan plan,
    ByedpiNodeLayout layout,
  ) async {
    final file = File(layout.configPath);
    final content = file.existsSync()
        ? await file.readAsString()
        : readConfigArtifact(plan);
    final value = json.decode(content);
    if (value is! Map) {
      throw StateError('byedpi node `${plan.name}` config is not an object.');
    }
    final test = _asMap(value['strategyTest']);
    final cache = _asMap(value['cache']);
    final selection = _asMap(value['selection']);
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
      testSni: '${test['sni'] ?? _defaultByedpiStrategyTestSni}',
      resolver: switch ('${test['resolver'] ?? ''}'.trim()) {
        '' => _defaultByedpiProbeResolver,
        final value => value,
      },
      timeout: Duration(seconds: (test['timeout'] as num?)?.toInt() ?? 5),
      requests: (test['requests'] as num?)?.toInt() ?? 1,
      concurrency: (test['concurrency'] as num?)?.toInt() ?? 4,
      minSuccessRatio: (test['min-success-ratio'] as num?)?.toDouble() ?? 1.0,
      cacheTtl: Duration(seconds: (cache['ttl'] as num?)?.toInt() ?? 604800),
      recheckAfter: Duration(
        seconds: (cache['recheck-after'] as num?)?.toInt() ?? 86400,
      ),
      failureThreshold: (cache['failure-threshold'] as num?)?.toInt() ?? 2,
      retryAfter: Duration(
        seconds: (cache['retry-after'] as num?)?.toInt() ?? 300,
      ),
      selectionConcurrency: (selection['concurrency'] as num?)?.toInt() ?? 4,
      foregroundTimeout: Duration(
        seconds: (selection['foreground-timeout'] as num?)?.toInt() ?? 15,
      ),
      backgroundSelection: selection['background'] as bool? ?? true,
      fallbackStrategy:
          '${value['fallbackArgs'] ?? _byedpiAutoFallbackStrategy}',
    );
  }

  Future<_ByedpiStrategyCache?> _readCache(ByedpiNodeLayout layout) async {
    final file = File(layout.cachePath);
    if (!file.existsSync()) return null;
    try {
      return _ByedpiStrategyCache.fromJson(await file.readAsString());
    } catch (error) {
      commonPrint.log(
        'byedpi ignored an unreadable strategy cache at ${layout.cachePath}: '
        '$error',
      );
      return null;
    }
  }

  Future<void> _writeCache(
    ByedpiNodeLayout layout,
    _ByedpiStrategyCache cache,
  ) async {
    final target = File(layout.cachePath);
    final temporary = File('${layout.cachePath}.tmp');
    await temporary.writeAsString(json.encode(cache.toJson()), flush: true);
    await temporary.rename(target.path);
  }

  Future<void> _restoreCache(
    ByedpiNodeLayout layout,
    _ByedpiStrategyCache cache,
  ) =>
      _writeCache(layout, cache);

  bool _matchesCurrentCache(
    _ByedpiStrategyCache? cache,
    String fingerprint,
  ) =>
      cache != null &&
      cache.selectionRevision == _byedpiAutoSelectionRevision &&
      cache.fingerprint == fingerprint;

  bool _needsRecheck(_ByedpiStrategyCache cache, _ByedpiConfig config) =>
      now().difference(cache.checkedAt) >= config.recheckAfter;

  _ByedpiStrategyCache _verifiedCache({
    required String fingerprint,
    required String strategy,
  }) =>
      _ByedpiStrategyCache(
        fingerprint: fingerprint,
        strategy: strategy,
        checkedAt: now(),
        failures: 0,
        selectionRevision: _byedpiAutoSelectionRevision,
        verified: true,
        nextIndex: 0,
      );

  _ByedpiStrategyCache _provisionalCache({
    required String fingerprint,
    required String strategy,
    required int nextIndex,
  }) =>
      _ByedpiStrategyCache(
        fingerprint: fingerprint,
        strategy: strategy,
        checkedAt: now(),
        failures: 0,
        selectionRevision: _byedpiAutoSelectionRevision,
        verified: false,
        nextIndex: nextIndex,
      );

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
                'resolver': config.resolver,
                'timeout': config.timeout.inSeconds,
                'requests': config.requests,
                'concurrency': config.concurrency,
                'minSuccessRatio': config.minSuccessRatio,
                'fallbackStrategy': config.fallbackStrategy,
              }),
            ),
          )
          .toString();

  Future<List<int>> _allocateDistinctProbePorts(int count) async {
    final ports = <int>{};
    final maximumAttempts = count * 16 + 16;
    var attempts = 0;
    while (ports.length < count && attempts < maximumAttempts) {
      ports.add(await allocateProbePort());
      attempts++;
    }
    if (ports.length != count) {
      throw StateError(
        'Could not allocate $count distinct ByeDPI probe ports after '
        '$maximumAttempts attempts.',
      );
    }
    return ports.toList(growable: false);
  }

  int _wholeSeconds(Duration duration) =>
      (duration.inMilliseconds / Duration.millisecondsPerSecond).ceil();

  Map<String, dynamic> _asMap(Object? value) {
    if (value is! Map) return <String, dynamic>{};
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
      } else if (char == r'\') {
        escape = true;
      } else if (quote.isNotEmpty) {
        if (char == quote) {
          quote = '';
        } else {
          buffer.write(char);
        }
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          args.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) args.add(buffer.toString());
    return args;
  }

  static Future<int> _allocateLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Duration _readMonotonicClock() => _byedpiMonotonicClock.elapsed;
}
