import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/common/common.dart';
import 'package:path/path.dart' as path;

import '../platform/product_install_layout.dart';
import 'desktop_process_supervisor.dart';
import 'desktop_runtime_layout.dart';

class DesktopRuntimeNodeBridge
    implements
        RuntimeNodePlatformBridge,
        RuntimeNodeProbePlatformBridge,
        RuntimeNodeBatchProbePlatformBridge {
  DesktopRuntimeNodeBridge({
    DesktopProcessSupervisor? supervisor,
    DesktopRuntimeLayout? layout,
    Future<List<String>> Function()? readSystemDns,
  })  : supervisor = supervisor ?? desktopProcessSupervisor,
        layout = layout ?? DesktopRuntimeLayout.current(),
        _readSystemDns = readSystemDns ?? _defaultSystemDns;

  final DesktopProcessSupervisor supervisor;
  final DesktopRuntimeLayout layout;
  final Future<List<String>> Function() _readSystemDns;

  List<Map<String, dynamic>> _nodes = const [];
  int _generation = 0;
  RuntimeNodePlanState _state = const RuntimeNodePlanState(
    generation: 0,
    status: 'idle',
    message: '',
    nodes: [],
    optionalCheckActive: false,
  );
  Future<void> _mutation = Future<void>.value();
  Timer? _dnsWatcher;
  String _dnsFingerprint = '';
  final Map<String, int> _crashCounts = {};

  @override
  Future<RuntimeNodePlanState> applyPlan(List<Map<String, dynamic>> nodes) =>
      _serialize(() async {
        final next = await Future.wait([
          for (final node in nodes) _validateNode(node),
        ]);
        final previous = _nodes;
        final generation = ++_generation;
        _state = RuntimeNodePlanState(
          generation: generation,
          status: 'starting',
          message: '',
          nodes: next,
          optionalCheckActive: false,
        );
        try {
          await _replace(previous: previous, next: next);
          _nodes = List.unmodifiable(next);
          _crashCounts.removeWhere(
            (nodeId, _) => !next.any((node) => node['nodeId'] == nodeId),
          );
          _state = RuntimeNodePlanState(
            generation: generation,
            status: next.isEmpty ? 'idle' : 'ready',
            message: '',
            nodes: next,
            optionalCheckActive: false,
          );
          _syncDnsWatcher();
        } catch (error) {
          await _stopNodes(next);
          try {
            await _startNodes(previous);
            _nodes = previous;
          } catch (rollbackError) {
            _nodes = const [];
            _state = RuntimeNodePlanState(
              generation: generation,
              status: 'failed',
              message: '$error Rollback failed: $rollbackError',
              nodes: const [],
              optionalCheckActive: false,
            );
            return _state;
          }
          _state = RuntimeNodePlanState(
            generation: generation,
            status: 'failed',
            message: '$error',
            nodes: previous,
            optionalCheckActive: false,
          );
        }
        return _state;
      });

  @override
  Future<RuntimeNodePlanState> readPlanState() async => _state;

  @override
  Future<void> stopPlan() => _serialize(() async {
        _dnsWatcher?.cancel();
        _dnsWatcher = null;
        await _stopNodes(_nodes);
        _nodes = const [];
        _state = RuntimeNodePlanState(
          generation: ++_generation,
          status: 'idle',
          message: '',
          nodes: const [],
          optionalCheckActive: false,
        );
      });

  @override
  Future<bool> probeNode(Map<String, dynamic> node) async {
    final candidate = await _validateNode(node);
    final identity =
        'probe:${candidate['nodeId']}:${DateTime.now().microsecondsSinceEpoch}';
    try {
      return await _startAndCheck(candidate, identity: identity);
    } catch (_) {
      return false;
    } finally {
      await supervisor.stop(identity);
    }
  }

  @override
  Future<int?> probeNodes(
    List<Map<String, dynamic>> nodes, {
    required int concurrency,
  }) async {
    if (nodes.isEmpty) return null;
    final limit = concurrency.clamp(1, 16);
    var next = 0;
    int? winner;
    Future<void> worker() async {
      while (winner == null && next < nodes.length) {
        final index = next++;
        if (await probeNode(nodes[index]) && winner == null) winner = index;
      }
    }

    await Future.wait([for (var index = 0; index < limit; index++) worker()]);
    return winner;
  }

  @override
  Future<void> saveColdStartNodes(String manifestJson) async {
    final file = File(
      path.join(await appPath.homeDirPath, 'desktop-runtime', 'nodes.json'),
    );
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(manifestJson, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> clearColdStartNodes() async {
    final file = File(
      path.join(await appPath.homeDirPath, 'desktop-runtime', 'nodes.json'),
    );
    if (await file.exists()) await file.delete();
  }

  Future<void> _replace({
    required List<Map<String, dynamic>> previous,
    required List<Map<String, dynamic>> next,
  }) async {
    final unchangedIds = <String>{};
    for (final node in next) {
      final old = previous.where((item) => item['nodeId'] == node['nodeId']);
      if (old.isNotEmpty && old.first['revision'] == node['revision']) {
        unchangedIds.add(node['nodeId'] as String);
      }
    }
    await _stopNodes(
      previous.where((node) => !unchangedIds.contains(node['nodeId'])),
    );
    await _startNodes(
      next.where((node) => !unchangedIds.contains(node['nodeId'])),
    );
  }

  Future<void> _startNodes(Iterable<Map<String, dynamic>> nodes) async {
    final started = <Map<String, dynamic>>[];
    try {
      for (final node in nodes) {
        if (!await _startAndCheck(node, identity: _identity(node))) {
          final output = supervisor.outputFor(_identity(node)).trim();
          throw StateError(
            'Desktop runtime node `${node['name']}` did not pass its SOCKS check.'
            '${output.isEmpty ? '' : ' Output: $output'}',
          );
        }
        started.add(node);
      }
    } catch (_) {
      await _stopNodes(started);
      rethrow;
    }
  }

  Future<bool> _startAndCheck(
    Map<String, dynamic> node, {
    required String identity,
  }) async {
    await _renderResolver(node);
    await supervisor.spawn(
      identity: identity,
      executable: node['executablePath'] as String,
      arguments: List<String>.from(node['arguments'] as List? ?? const []),
      workingDirectory: node['workingDirectory'] as String,
      onUnexpectedExit: identity.startsWith('node:')
          ? (_) => _recoverNode(node, _generation)
          : null,
    );
    final check = Map<String, dynamic>.from(
      node['connectivityCheck'] as Map? ?? const {},
    );
    final startupTimeout = Duration(
      seconds: (check['startup-timeout'] as num?)?.toInt() ?? 30,
    );
    final ready = await supervisor.waitForSocks(
      identity: identity,
      host: node['host'] as String,
      port: node['port'] as int,
      timeout: startupTimeout,
      retryInterval: Duration(
        seconds: (check['retry-interval'] as num?)?.toInt() ?? 1,
      ),
    );
    if (!ready) return false;
    final urls = (check['urls'] as List? ?? const [])
        .map((item) => Uri.parse('$item'))
        .toList();
    if (urls.isEmpty || check['required'] != true) return true;
    var success = 0;
    final requests = (check['requests'] as num?)?.toInt() ?? 1;
    final timeout = Duration(seconds: (check['timeout'] as num?)?.toInt() ?? 5);
    for (var index = 0; index < requests; index++) {
      final uri = urls[index % urls.length];
      if (await supervisor.probeSocksHttp(
        host: node['host'] as String,
        port: node['port'] as int,
        uri: uri,
        timeout: timeout,
      )) {
        success++;
      }
    }
    final ratio = (check['min-success-ratio'] as num?)?.toDouble() ?? 1;
    return success / requests >= ratio;
  }

  Future<void> _stopNodes(Iterable<Map<String, dynamic>> nodes) =>
      Future.wait([for (final node in nodes) supervisor.stop(_identity(node))]);

  Future<void> _recoverNode(Map<String, dynamic> node, int generation) =>
      _serialize(() async {
        if (generation != _generation ||
            !_nodes.any((item) => item['nodeId'] == node['nodeId'])) {
          return;
        }
        final nodeId = node['nodeId'] as String;
        final crashes = (_crashCounts[nodeId] ?? 0) + 1;
        _crashCounts[nodeId] = crashes;
        if (crashes > 3) {
          _state = RuntimeNodePlanState(
            generation: generation,
            status: 'failed',
            message: 'Desktop runtime node `${node['name']}` crash loop.',
            nodes: _nodes,
            optionalCheckActive: false,
          );
          await _stopNodes(_nodes);
          return;
        }
        await Future<void>.delayed(Duration(seconds: crashes));
        if (generation != _generation) return;
        final recovered = await _startAndCheck(
          node,
          identity: _identity(node),
        );
        if (!recovered) {
          _state = RuntimeNodePlanState(
            generation: generation,
            status: 'failed',
            message: 'Desktop runtime node `${node['name']}` did not recover.',
            nodes: _nodes,
            optionalCheckActive: false,
          );
          await _stopNodes(_nodes);
        }
      });

  String _identity(Map<String, dynamic> node) => 'node:${node['nodeId']}';

  Future<Map<String, dynamic>> _validateNode(
    Map<String, dynamic> source,
  ) async {
    final node = Map<String, dynamic>.from(source);
    final type = '${node['type']}';
    final artifact = switch (type) {
      'naiveproxy' => ProductInstallLayout.naiveproxyArtifact,
      'olcrtc' => ProductInstallLayout.olcrtcArtifact,
      'byedpi' => ProductInstallLayout.byedpiArtifact,
      'stormdns' => ProductInstallLayout.stormdnsArtifact,
      _ => throw StateError('Unsupported desktop runtime node type `$type`.'),
    };
    final expected = path.normalize(
      path.absolute(layout.artifactPath(artifact)),
    );
    final executable = path.normalize(
      path.absolute('${node['executablePath']}'),
    );
    if (executable != expected || !File(executable).existsSync()) {
      throw StateError(
        'Desktop runtime node `$type` has an unexpected binary.',
      );
    }
    final workingDirectory = path.normalize(
      path.absolute('${node['workingDirectory']}'),
    );
    final dataRoot =
        layout.dataRoot.isEmpty ? await appPath.homeDirPath : layout.dataRoot;
    final nodesRoot = path.normalize(
      path.absolute(path.join(dataRoot, 'desktop-runtime', 'nodes')),
    );
    if (!path.isWithin(nodesRoot, workingDirectory)) {
      throw StateError(
        'Desktop runtime node working directory escaped its root.',
      );
    }
    if (node['host'] != '127.0.0.1' ||
        node['port'] is! int ||
        (node['port'] as int) < 1 ||
        (node['port'] as int) > 65535) {
      throw StateError('Desktop runtime node has an unsafe listener.');
    }
    node['executablePath'] = executable;
    node['workingDirectory'] = workingDirectory;
    return node;
  }

  Future<void> _renderResolver(Map<String, dynamic> node) async {
    final raw = node['resolverFile'];
    if (raw is! Map) return;
    final spec = Map<String, dynamic>.from(raw);
    final root = Directory(node['workingDirectory'] as String);
    final template = _inside(root.path, '${spec['template']}');
    final target = _inside(root.path, '${spec['path']}');
    final source = await File(template).readAsString();
    final dns = spec['dependsOnSystemDns'] == true
        ? await _readSystemDns()
        : const <String>[];
    final lines = <String>[];
    for (final rawLine in const LineSplitter().convert(source)) {
      final line = rawLine.trim();
      if (line == '# @flclashm:system-dns') {
        lines.addAll(dns);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        lines.add(line);
      }
    }
    if (lines.isEmpty) throw StateError('Desktop system DNS is unavailable.');
    final rendered = '${lines.toSet().join('\n')}\n';
    final file = File(target);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(rendered, flush: true);
    await temp.rename(file.path);
  }

  String _inside(String root, String relative) {
    if (path.isAbsolute(relative))
      throw StateError('Absolute runtime artifact path.');
    final resolved = path.normalize(path.absolute(path.join(root, relative)));
    if (!path.isWithin(path.normalize(path.absolute(root)), resolved)) {
      throw StateError('Runtime artifact escaped its working directory.');
    }
    return resolved;
  }

  void _syncDnsWatcher() {
    _dnsWatcher?.cancel();
    if (!_nodes.any(
      (node) =>
          node['resolverFile'] is Map &&
          (node['resolverFile'] as Map)['dependsOnSystemDns'] == true,
    )) {
      return;
    }
    _dnsWatcher = Timer.periodic(const Duration(seconds: 5), (_) async {
      final dns = await _readSystemDns();
      final fingerprint = dns.join(',');
      if (_dnsFingerprint.isEmpty) {
        _dnsFingerprint = fingerprint;
      } else if (fingerprint != _dnsFingerprint) {
        _dnsFingerprint = fingerprint;
        unawaited(applyPlan(_nodes));
      }
    });
  }

  static Future<List<String>> _defaultSystemDns() async {
    if (!Platform.isLinux) return const [];
    final file = File('/etc/resolv.conf');
    if (!await file.exists()) return const [];
    final lines = await file.readAsLines();
    return [
      for (final line in lines)
        if (line.trimLeft().startsWith('nameserver '))
          line.trim().split(RegExp(r'\s+'))[1],
    ];
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutation = _mutation.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
