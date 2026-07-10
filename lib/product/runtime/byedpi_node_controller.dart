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

const _byedpiAutoFallbackStrategy = '--disorder 1 --auto=torst --tlsrec 1+s';
const _byedpiAutoMaxProbeCount = 4;
const _byedpiAutoProbeTimeout = Duration(seconds: 1);

@immutable
class ByedpiSharedInstallLayout extends LocalNodeSharedInstallLayout {
  const ByedpiSharedInstallLayout({
    required super.abi,
    required super.runtimeRootPath,
    required super.nodesDirectoryPath,
    required super.executablePath,
    required super.pendingPath,
    required super.rollbackPath,
    required super.versionPath,
    required super.pendingVersionPath,
    required super.bundledAssetPath,
    super.managedBinaryUpdateEnabled = true,
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
    Duration? timeout,
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
        timeout: timeout ?? this.timeout,
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

class ByedpiNodeController
    extends LocalNodeController<ByedpiSharedInstallLayout, ByedpiNodeLayout> {
  ByedpiNodeController({
    ByedpiBinaryBridge binary = const DefaultByedpiBinaryBridge(),
    super.runtime = const AndroidRuntimeNodeBridge(),
    super.waitForListener = _waitForRuntimeNodeListener,
    this.siteCheck = _checkUrlViaSocks,
    this.allocateProbePort = _allocateLoopbackPort,
    DateTime Function()? now,
  })  : now = now ?? DateTime.now,
        super(
          typeLabel: 'byedpi',
          configArtifactName: 'config.json',
          binary: binary,
          startMode: LocalNodeStartMode.parallel,
        );

  final ByedpiSiteCheckCallback siteCheck;
  final ByedpiProbePortAllocator allocateProbePort;
  final DateTime Function() now;

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
  Future<bool> startPlan(
    ByedpiSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    ByedpiNodeLayout layout,
  ) async {
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

  @override
  Future<void> confirmStageRestart(BuiltInProxyNodePlan plan) async {}

  @override
  Future<LocalNodeColdStartExtras> buildColdStartExtras(
    BuiltInProxyNodePlan plan,
    ByedpiSharedInstallLayout sharedLayout,
    ByedpiNodeLayout layout,
  ) async {
    final config = await _readNodeConfig(plan, layout);
    if (!config.isAuto) {
      return LocalNodeColdStartExtras(
        extraFields: {
          'arguments': _buildArguments(config.args, config),
        },
      );
    }
    final cached = await _readCache(layout);
    if (cached == null) {
      return const LocalNodeColdStartExtras.skip();
    }
    return LocalNodeColdStartExtras(
      extraFields: {
        'arguments': _buildArguments(cached.strategy, config),
      },
    );
  }

  @override
  Future<String> rollbackStageFailure({
    required List<LocalNodeMutation<ByedpiNodeLayout>> mutations,
    required String failureMessage,
  }) async {
    for (final mutation in mutations.reversed) {
      await runtime.stopNode(nodeId: mutation.plan.nodeId);
      final configFile = File(mutation.layout.configPath);
      if (mutation.previousConfig == null) {
        await deleteFileWithRetry(configFile);
        await deleteDirectoryIfExists(
          Directory(mutation.layout.workingDirectoryPath),
        );
      } else {
        await configFile.writeAsString(mutation.previousConfig!, flush: true);
      }
      if (mutation.wasRunning) {
        final sharedLayout = await binary.resolveSharedInstallLayout();
        final rollbackPlan = mutation.previousPlan ?? mutation.plan;
        final restarted = await startPlan(
          sharedLayout,
          rollbackPlan,
          mutation.layout,
        );
        if (!restarted) {
          return '$failureMessage Rollback failed: previous byedpi node did not restart.';
        }
      }
    }
    return failureMessage;
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
        return _startWithStrategy(
            sharedLayout, plan, layout, config, cached.strategy);
      }
      final started = await _startWithStrategy(
        sharedLayout,
        plan,
        layout,
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
        return _startWithStrategy(
          sharedLayout,
          plan,
          layout,
          config,
          cached.strategy,
        );
      }
    }

    final selected = await _selectStrategy(
      sharedLayout,
      plan,
      layout,
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
      return _startWithStrategy(sharedLayout, plan, layout, config, selected);
    }

    if (cached != null && cached.fingerprint == fingerprint) {
      commonPrint.log(
        'byedpi node `${plan.name}` did not find a new strategy; using cached strategy.',
      );
      return _startWithStrategy(
        sharedLayout,
        plan,
        layout,
        config,
        cached.strategy,
      );
    }

    commonPrint.log(
      'byedpi node `${plan.name}` did not select a strategy quickly; '
      'using bundled fallback.',
    );
    await _writeCache(
      layout,
      _ByedpiStrategyCache(
        fingerprint: fingerprint,
        strategy: _byedpiAutoFallbackStrategy,
        checkedAt: now(),
        failures: 0,
      ),
    );
    return _startWithStrategy(
      sharedLayout,
      plan,
      layout,
      config,
      _byedpiAutoFallbackStrategy,
    );
  }

  Future<String?> _selectStrategy(
    ByedpiSharedInstallLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    ByedpiNodeLayout layout,
    _ByedpiConfig config,
    List<String> strategies,
  ) async {
    for (final strategy in strategies.take(_byedpiAutoMaxProbeCount)) {
      final probePort = await allocateProbePort();
      final probeConfig = config.copyWith(
        listenPort: probePort,
        timeout: _shorterDuration(config.timeout, _byedpiAutoProbeTimeout),
      );
      final probeNodeId = '${plan.nodeId}-probe-${strategy.toMd5()}';
      final started = await _startWithStrategy(
        sharedLayout,
        plan,
        layout,
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
    ByedpiNodeLayout layout,
    _ByedpiConfig config,
    String strategy, {
    String? nodeId,
  }) async {
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

  Duration _shorterDuration(Duration left, Duration right) =>
      left <= right ? left : right;

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
    _SocketByteReader? reader;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      final targetHost = url.host;
      final targetPort =
          url.hasPort ? url.port : (url.scheme == 'http' ? 80 : 443);
      reader = _SocketByteReader(socket);
      await _performSocksGreeting(
        socket: socket,
        reader: reader,
        timeout: timeout,
      );
      await _performSocksConnect(
        socket: socket,
        reader: reader,
        targetHost: targetHost,
        targetPort: targetPort,
        timeout: timeout,
      );
      if (_usesTls(url, targetPort)) {
        socket = await SecureSocket.secure(
          socket,
          host: targetHost,
        ).timeout(timeout);
        reader = _SocketByteReader(socket);
      }
      socket.add(
        utf8.encode(
          _buildHttpProbeRequest(
            url: url,
            targetHost: targetHost,
            targetPort: targetPort,
          ),
        ),
      );
      await socket.flush().timeout(timeout);
      final readPhaseStopwatch = Stopwatch()..start();
      final statusLine = await reader.readLine(
        timeout: timeout,
        maxLength: 4096,
        elapsed: () => readPhaseStopwatch.elapsed,
      );
      return _isValidHttpStatusLine(statusLine);
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<void> _performSocksGreeting({
    required Socket socket,
    required _SocketByteReader reader,
    required Duration timeout,
  }) async {
    socket.add(const [0x05, 0x01, 0x00]);
    await socket.flush().timeout(timeout);
    final response = await reader.readBytes(2, timeout);
    if (response[0] != 0x05 || response[1] != 0x00) {
      throw const SocketException('SOCKS5 greeting failed');
    }
  }

  static Future<void> _performSocksConnect({
    required Socket socket,
    required _SocketByteReader reader,
    required String targetHost,
    required int targetPort,
    required Duration timeout,
  }) async {
    socket.add(_buildSocksConnectRequest(targetHost, targetPort));
    await socket.flush().timeout(timeout);
    final header = await reader.readBytes(4, timeout);
    if (header[0] != 0x05 || header[1] != 0x00 || header[2] != 0x00) {
      throw const SocketException('SOCKS5 connect failed');
    }
    await _discardSocksAddress(reader, header[3], timeout);
    await reader.readBytes(2, timeout);
  }

  static List<int> _buildSocksConnectRequest(String host, int port) {
    final address = InternetAddress.tryParse(host);
    if (address?.type == InternetAddressType.IPv4) {
      return [
        0x05,
        0x01,
        0x00,
        0x01,
        ...address!.rawAddress,
        (port >> 8) & 0xff,
        port & 0xff,
      ];
    }
    if (address?.type == InternetAddressType.IPv6) {
      return [
        0x05,
        0x01,
        0x00,
        0x04,
        ...address!.rawAddress,
        (port >> 8) & 0xff,
        port & 0xff,
      ];
    }
    final hostBytes = utf8.encode(host);
    if (hostBytes.length > 255) {
      throw const SocketException('SOCKS5 host name is too long');
    }
    return [
      0x05,
      0x01,
      0x00,
      0x03,
      hostBytes.length,
      ...hostBytes,
      (port >> 8) & 0xff,
      port & 0xff,
    ];
  }

  static Future<void> _discardSocksAddress(
    _SocketByteReader reader,
    int addressType,
    Duration timeout,
  ) async {
    switch (addressType) {
      case 0x01:
        await reader.readBytes(4, timeout);
        return;
      case 0x03:
        final length = (await reader.readBytes(1, timeout)).single;
        await reader.readBytes(length, timeout);
        return;
      case 0x04:
        await reader.readBytes(16, timeout);
        return;
      default:
        throw const SocketException('SOCKS5 returned unknown address type');
    }
  }

  static bool _usesTls(Uri url, int targetPort) =>
      url.scheme == 'https' || targetPort == 443;

  static String _buildHttpProbeRequest({
    required Uri url,
    required String targetHost,
    required int targetPort,
  }) {
    final requestTarget = url.path.isEmpty
        ? '/${url.hasQuery ? '?${url.query}' : ''}'
        : '${url.path}${url.hasQuery ? '?${url.query}' : ''}';
    final defaultPort = url.scheme == 'http' ? 80 : 443;
    final hostHeader = targetHost.contains(':') ? '[$targetHost]' : targetHost;
    final authority = url.hasPort && targetPort != defaultPort
        ? '$hostHeader:$targetPort'
        : hostHeader;
    return 'HEAD $requestTarget HTTP/1.1\r\n'
        'Host: $authority\r\n'
        'Connection: close\r\n'
        '\r\n';
  }

  static bool _isValidHttpStatusLine(String statusLine) {
    final match = RegExp(r'^HTTP/\d\.\d\s+([1-5]\d{2})\b').firstMatch(
      statusLine.trim(),
    );
    if (match == null) {
      return false;
    }
    final statusCode = int.tryParse(match.group(1) ?? '');
    return statusCode != null && statusCode >= 100 && statusCode <= 599;
  }
}

class _SocketByteReader {
  _SocketByteReader(Stream<List<int>> stream)
      : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  List<int> _buffer = <int>[];

  Future<List<int>> readBytes(int length, Duration timeout) async {
    while (_buffer.length < length) {
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) {
        throw const SocketException('Unexpected socket close');
      }
      _buffer.addAll(_iterator.current);
    }
    return _take(length);
  }

  Future<String> readLine({
    required Duration timeout,
    required int maxLength,
    Duration Function()? elapsed,
  }) async {
    while (true) {
      final newlineIndex = _buffer.indexOf(0x0a);
      if (newlineIndex != -1) {
        return _decodeLine(_take(newlineIndex + 1));
      }
      if (_buffer.length >= maxLength) {
        return _decodeLine(_take(maxLength));
      }
      final hasNext = await _iterator.moveNext().timeout(
            _remainingTimeout(timeout, elapsed),
          );
      if (!hasNext) {
        if (_buffer.isEmpty) {
          throw const SocketException('Unexpected socket close');
        }
        return _decodeLine(_take(_buffer.length));
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Duration _remainingTimeout(
    Duration timeout,
    Duration Function()? elapsed,
  ) {
    if (elapsed == null) {
      return timeout;
    }
    final remaining = timeout - elapsed();
    if (remaining <= Duration.zero) {
      throw TimeoutException('Socket read timed out');
    }
    return remaining;
  }

  List<int> _take(int length) {
    final result = _buffer.sublist(0, length);
    _buffer = length == _buffer.length ? <int>[] : _buffer.sublist(length);
    return result;
  }

  String _decodeLine(List<int> bytes) {
    var end = bytes.length;
    if (end > 0 && bytes[end - 1] == 0x0a) {
      end--;
    }
    if (end > 0 && bytes[end - 1] == 0x0d) {
      end--;
    }
    return latin1.decode(bytes.sublist(0, end));
  }
}
