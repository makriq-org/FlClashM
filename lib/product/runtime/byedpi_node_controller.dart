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
const _byedpiAutoSelectionRevision = 1;

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

  _ByedpiConfig withListenPort(int listenPort) => _ByedpiConfig(
        mode: mode,
        listenHost: listenHost,
        listenPort: listenPort,
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
    required this.selectionRevision,
  });

  final String fingerprint;
  final String strategy;
  final DateTime checkedAt;
  final int failures;
  final int selectionRevision;

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'strategy': strategy,
        'checkedAt': checkedAt.toIso8601String(),
        'failures': failures,
        'selectionRevision': selectionRevision,
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
    );
  }
}

class ByedpiNodeController
    extends LocalNodeController<ByedpiSharedInstallLayout, ByedpiNodeLayout> {
  ByedpiNodeController({
    ByedpiBinaryBridge binary = const DefaultByedpiBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
    this.allocateProbePort = _allocateLoopbackPort,
    DateTime Function()? now,
  })  : now = now ?? DateTime.now,
        super(
          typeLabel: 'byedpi',
          configArtifactName: 'config.json',
          binary: binary,
        );

  final DateTime Function() now;
  final ByedpiProbePortAllocator allocateProbePort;

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
    if (_canUseCache(cached, fingerprint, config)) {
      if (!_needsRecheck(cached!, config)) return cached.strategy;
      if (await _probeStrategy(
        plan: plan,
        sharedLayout: sharedLayout,
        layout: layout,
        config: config,
        strategy: cached.strategy,
      )) {
        await _writeCache(
          layout,
          _ByedpiStrategyCache(
            fingerprint: fingerprint,
            strategy: cached.strategy,
            checkedAt: now(),
            failures: 0,
            selectionRevision: _byedpiAutoSelectionRevision,
          ),
        );
        return cached.strategy;
      }
      final failures = cached.failures + 1;
      if (failures < config.failureThreshold) {
        await _writeCache(
          layout,
          _ByedpiStrategyCache(
            fingerprint: fingerprint,
            strategy: cached.strategy,
            checkedAt: cached.checkedAt,
            failures: failures,
            selectionRevision: _byedpiAutoSelectionRevision,
          ),
        );
        return cached.strategy;
      }
    }

    for (final strategy in strategies) {
      if (await _probeStrategy(
        plan: plan,
        sharedLayout: sharedLayout,
        layout: layout,
        config: config,
        strategy: strategy,
      )) {
        await _writeCache(
          layout,
          _ByedpiStrategyCache(
            fingerprint: fingerprint,
            strategy: strategy,
            checkedAt: now(),
            failures: 0,
            selectionRevision: _byedpiAutoSelectionRevision,
          ),
        );
        return strategy;
      }
    }

    if (_matchesCurrentCache(cached, fingerprint)) {
      commonPrint.log(
        'byedpi node `${plan.name}` did not find a new strategy; using cached strategy.',
      );
      return cached!.strategy;
    }
    commonPrint.log(
      'byedpi node `${plan.name}` did not select a strategy; '
      'using bundled fallback.',
    );
    final fallback = _ByedpiStrategyCache(
      fingerprint: fingerprint,
      strategy: _byedpiAutoFallbackStrategy,
      checkedAt: now(),
      failures: 0,
      selectionRevision: _byedpiAutoSelectionRevision,
    );
    await _writeCache(layout, fallback);
    return fallback.strategy;
  }

  Future<bool> _probeStrategy({
    required BuiltInProxyNodePlan plan,
    required ByedpiSharedInstallLayout sharedLayout,
    required ByedpiNodeLayout layout,
    required _ByedpiConfig config,
    required String strategy,
  }) async {
    final RuntimeNodeProbePlatformBridge probeBridge;
    if (runtime case final RuntimeNodeProbePlatformBridge bridge) {
      probeBridge = bridge;
    } else {
      return false;
    }
    final probePort = await allocateProbePort();
    final probeConfig = config.withListenPort(probePort);
    final timeoutSeconds = probeConfig.timeout.inSeconds.clamp(1, 60);
    final startupTimeoutSeconds = (timeoutSeconds * 2).clamp(2, 300);
    final probeNodeId = '${plan.nodeId}-probe-${strategy.toMd5()}';
    try {
      return await probeBridge.probeNode(<String, dynamic>{
        'nodeId': probeNodeId,
        'type': plan.type.label,
        'name': '${plan.name} strategy probe',
        'host': probeConfig.listenHost,
        'port': probeConfig.listenPort,
        'executablePath': sharedLayout.executablePath,
        'workingDirectory': layout.workingDirectoryPath,
        'arguments': _buildArguments(strategy, probeConfig),
        'revision': sha256.convert(utf8.encode(strategy)).toString(),
        'connectivityCheck': <String, dynamic>{
          'urls': probeConfig.testUrls.map((url) => '$url').toList(),
          'required': true,
          'timeout': timeoutSeconds,
          'startup-timeout': startupTimeoutSeconds,
          'retry-interval': 1,
          'requests': probeConfig.requests,
          'concurrency': probeConfig.concurrency,
          'min-success-ratio': probeConfig.minSuccessRatio,
        },
      });
    } catch (error) {
      commonPrint.log(
        'byedpi node `${plan.name}` strategy probe failed: $error',
      );
      return false;
    }
  }

  List<String> _buildArguments(String strategy, _ByedpiConfig config) => [
        '--ip',
        config.listenHost,
        '--port',
        config.listenPort.toString(),
        ..._splitShell(strategy.replaceAll('{sni}', config.testSni)),
      ];

  Future<List<String>> _resolveStrategies(_ByedpiConfig config) async {
    if (config.strategies.isNotEmpty) return config.strategies;
    if (config.strategyList != 'byebyeedpi') return const [];
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
        : readConfigArtifact(plan);
    final value = json.decode(content);
    if (value is! Map) {
      throw StateError('byedpi node `${plan.name}` config is not an object.');
    }
    final test = _asMap(value['strategyTest']);
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
      testSni: '${test['sni'] ?? (urls.isEmpty ? '' : urls.first.host)}',
      timeout: Duration(seconds: (test['timeout'] as num?)?.toInt() ?? 5),
      requests: (test['requests'] as num?)?.toInt() ?? 1,
      concurrency: (test['concurrency'] as num?)?.toInt() ?? 4,
      minSuccessRatio: (test['min-success-ratio'] as num?)?.toDouble() ?? 1.0,
      cacheTtl: Duration(seconds: (cache['ttl'] as num?)?.toInt() ?? 604800),
      recheckAfter: Duration(
        seconds: (cache['recheck-after'] as num?)?.toInt() ?? 86400,
      ),
      failureThreshold: (cache['failure-threshold'] as num?)?.toInt() ?? 2,
    );
  }

  Future<_ByedpiStrategyCache?> _readCache(ByedpiNodeLayout layout) async {
    final file = File(layout.cachePath);
    if (!file.existsSync()) return null;
    return _ByedpiStrategyCache.fromJson(await file.readAsString());
  }

  Future<void> _writeCache(
    ByedpiNodeLayout layout,
    _ByedpiStrategyCache cache,
  ) =>
      File(layout.cachePath).writeAsString(
        json.encode(cache.toJson()),
        flush: true,
      );

  bool _canUseCache(
    _ByedpiStrategyCache? cache,
    String fingerprint,
    _ByedpiConfig config,
  ) =>
      _matchesCurrentCache(cache, fingerprint) &&
      now().difference(cache!.checkedAt) <= config.cacheTtl;

  bool _matchesCurrentCache(
    _ByedpiStrategyCache? cache,
    String fingerprint,
  ) =>
      cache != null &&
      cache.selectionRevision == _byedpiAutoSelectionRevision &&
      cache.fingerprint == fingerprint;

  bool _needsRecheck(_ByedpiStrategyCache cache, _ByedpiConfig config) =>
      now().difference(cache.checkedAt) >= config.recheckAfter;

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
}
