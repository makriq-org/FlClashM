import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/byedpi_node_controller.dart';
import 'package:flclashx/product/runtime/byedpi_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ByedpiNodeController', () {
    late Directory tempDir;
    late ByedpiSharedInstallLayout layout;
    late _FakeRuntimeNodeBridge runtime;
    late ByedpiNodeController controller;
    late Duration monotonicTime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('byedpi-controller-');
      layout = ByedpiSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/libbyedpi.so',
      );
      runtime = _FakeRuntimeNodeBridge();
      monotonicTime = Duration.zero;
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(layout),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => DateTime.utc(2026, 1, 1),
        monotonicNow: () => monotonicTime,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('passes manual strategy and listener arguments to Android', () async {
      final plan = _plan(mode: 'manual', args: '--fake 1 --ttl "3 4"');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(node['type'], 'byedpi');
      expect(node['arguments'], [
        '--ip',
        '127.0.0.1',
        '--port',
        '35110',
        '--fake',
        '1',
        '--ttl',
        '3 4',
      ]);
    });

    test('uses google.com as the default strategy SNI', () async {
      runtime.batchResults.add(0);
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(
          layout,
          strategies: '--fake-sni {sni} --fake 1',
        ),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => DateTime.utc(2026, 1, 1),
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(mode: 'auto', args: '');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      await controller.buildRuntimeNodes([plan]);

      expect(
        runtime.batchCalls.single.nodes.single['arguments'],
        containsAllInOrder(['--fake-sni', 'google.com']),
      );
    });

    test('persists fallback as provisional and honors its retry cooldown',
        () async {
      final plan = _plan(mode: 'auto', args: '');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final first = (await controller.buildRuntimeNodes([plan])).single;
      final second = (await controller.buildRuntimeNodes([plan])).single;
      final cache =
          File('${layout.nodesDirectoryPath}/node-a/strategy-cache.json');

      expect(first['arguments'], second['arguments']);
      expect(first['arguments'], containsAllInOrder(_defaultFallbackArgs));
      expect(cache.existsSync(), isTrue);
      final cached = json.decode(await cache.readAsString()) as Map;
      expect(cached['strategy'], isNotEmpty);
      expect(cached['verified'], isFalse);
      expect(runtime.batchCalls, hasLength(1));
    });

    test('selects and caches a strategy from one parallel native batch',
        () async {
      runtime.batchResults.add(1);
      final plan = _plan(mode: 'auto', args: '');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final first = (await controller.buildRuntimeNodes([plan])).single;
      final second = (await controller.buildRuntimeNodes([plan])).single;

      expect(runtime.batchCalls, hasLength(1));
      expect(runtime.batchCalls.single.nodes, hasLength(2));
      expect(runtime.batchCalls.single.concurrency, 4);
      expect(first['arguments'], containsAllInOrder(['--disorder', '1']));
      expect(second['arguments'], first['arguments']);
      expect(
        (runtime.batchCalls.single.nodes.singleWhere(
          (node) => (node['arguments'] as List).contains('--disorder'),
        )['connectivityCheck'] as Map)['required'],
        isTrue,
      );
      final cache = json.decode(await File(
        '${layout.nodesDirectoryPath}/node-a/strategy-cache.json',
      ).readAsString()) as Map;
      expect(cache['verified'], isTrue);
    });

    test('expands builtin markers in place and keeps first occurrence',
        () async {
      runtime.batchResults.add(0);
      final plan = _plan(
        mode: 'auto',
        args: '',
        strategies: const [
          'builtin:byebyeedpi',
          '--split 1',
          '--fake 1',
        ],
      );
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );

      await controller.buildRuntimeNodes([plan]);

      expect(
        runtime.batchCalls.single.nodes.map((node) => node['arguments']),
        [
          containsAllInOrder(['--fake', '1']),
          containsAllInOrder(['--disorder', '1']),
          containsAllInOrder(['--split', '1']),
        ],
      );
    });

    test('reselects in foreground after the verified cache TTL expires',
        () async {
      var wallClock = DateTime.utc(2026, 1, 1);
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(layout),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => wallClock,
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(
        mode: 'auto',
        args: '',
        cacheTtl: 1,
        recheckAfter: 1,
      );
      runtime.batchResults.addAll([0, 1]);
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );

      await controller.buildRuntimeNodes([plan]);
      wallClock = wallClock.add(const Duration(seconds: 2));
      await controller.buildRuntimeNodes([plan]);

      expect(runtime.batchCalls, hasLength(2));
    });

    test('bounds foreground selection and probes candidates concurrently',
        () async {
      const strategyCount = 60;
      runtime.onBatch = () => monotonicTime += const Duration(seconds: 5);
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(
          layout,
          strategies: List.generate(
            strategyCount,
            (index) => '--strategy ${index + 1}',
          ).join('\n'),
        ),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => DateTime.utc(2026, 1, 1),
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(
        mode: 'auto',
        args: '',
        timeout: 5,
        foregroundTimeout: 5,
      );
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(runtime.batchCalls, hasLength(1));
      expect(runtime.batchCalls.single.nodes, hasLength(4));
      expect(node['arguments'], containsAllInOrder(_defaultFallbackArgs));
      expect(
        runtime.batchCalls.single.nodes
            .map((probe) => (probe['connectivityCheck'] as Map)['timeout']),
        everyElement(5),
      );
      expect(
        runtime.batchCalls.single.nodes.map(
          (probe) => (probe['connectivityCheck'] as Map)['startup-timeout'],
        ),
        everyElement(5),
      );
      final cache = json.decode(await File(
        '${layout.nodesDirectoryPath}/node-a/strategy-cache.json',
      ).readAsString()) as Map;
      expect(cache['verified'], isFalse);
      expect(cache['nextIndex'], 4);
    });

    test('continues the remaining strategies in background and promotes one',
        () async {
      runtime.onBatch = () {
        if (runtime.batchCalls.length == 1) {
          monotonicTime += const Duration(seconds: 1);
        }
      };
      final strategies = List.generate(
        6,
        (index) => '--strategy ${index + 1}',
      ).join('\n');
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(layout, strategies: strategies),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => DateTime.utc(2026, 1, 1),
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(
        mode: 'auto',
        args: '',
        timeout: 1,
        foregroundTimeout: 1,
        selectionConcurrency: 2,
      );
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );
      await controller.buildRuntimeNodes([plan]);
      runtime.batchResults.add(1);
      final promoted = Completer<void>();

      controller.startBackgroundSelection(
        [plan],
        onSelectionChanged: () async {
          promoted.complete();
          return true;
        },
      );
      await promoted.future.timeout(const Duration(seconds: 1));

      expect(runtime.batchCalls, hasLength(2));
      final cache = json.decode(await File(
        '${layout.nodesDirectoryPath}/node-a/strategy-cache.json',
      ).readAsString()) as Map;
      expect(cache['verified'], isTrue);
      expect(cache['strategy'], '--strategy 4');
    });

    test('demotes a failed verified cache after the failure threshold',
        () async {
      var wallClock = DateTime.utc(2026, 1, 1);
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(layout),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => wallClock,
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(
        mode: 'auto',
        args: '',
        failureThreshold: 1,
        recheckAfter: 1,
      );
      runtime.batchResults.add(0);
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );
      await controller.buildRuntimeNodes([plan]);
      wallClock = wallClock.add(const Duration(seconds: 1));
      await controller.buildRuntimeNodes([plan]);
      final activated = Completer<void>();

      controller.startBackgroundSelection(
        [plan],
        onSelectionChanged: () async {
          activated.complete();
          return true;
        },
      );
      await activated.future.timeout(const Duration(seconds: 1));

      final cache = json.decode(await File(
        '${layout.nodesDirectoryPath}/node-a/strategy-cache.json',
      ).readAsString()) as Map;
      expect(cache['verified'], isFalse);
      expect((cache['strategy'] as String).split(' '), _defaultFallbackArgs);
    });

    test('restores the provisional cache when background activation fails',
        () async {
      runtime.onBatch = () {
        if (runtime.batchCalls.length == 1) {
          monotonicTime += const Duration(seconds: 1);
        }
      };
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(
          layout,
          strategies: List.generate(
            6,
            (index) => '--strategy ${index + 1}',
          ).join('\n'),
        ),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => DateTime.utc(2026, 1, 1),
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(
        mode: 'auto',
        args: '',
        timeout: 1,
        foregroundTimeout: 1,
        selectionConcurrency: 2,
      );
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );
      await controller.buildRuntimeNodes([plan]);
      final cache = File(
        '${layout.nodesDirectoryPath}/node-a/strategy-cache.json',
      );
      final provisional = json.decode(await cache.readAsString()) as Map;
      runtime.batchResults.add(0);
      var activationCalls = 0;
      final restored = Completer<void>();

      controller.startBackgroundSelection(
        [plan],
        onSelectionChanged: () async {
          activationCalls++;
          if (activationCalls == 2) restored.complete();
          if (activationCalls == 1) throw StateError('activation failed');
          return true;
        },
      );
      await restored.future.timeout(const Duration(seconds: 1));

      expect(activationCalls, 2);
      expect(json.decode(await cache.readAsString()), provisional);
    });

    test('ignores a stale background result after cancellation', () async {
      runtime.onBatch = () {
        if (runtime.batchCalls.length == 1) {
          monotonicTime += const Duration(seconds: 1);
        }
      };
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(
          layout,
          strategies: List.generate(
            6,
            (index) => '--strategy ${index + 1}',
          ).join('\n'),
        ),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
        now: () => DateTime.utc(2026, 1, 1),
        monotonicNow: () => monotonicTime,
      );
      final plan = _plan(
        mode: 'auto',
        args: '',
        timeout: 1,
        foregroundTimeout: 1,
        selectionConcurrency: 2,
      );
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );
      await controller.buildRuntimeNodes([plan]);
      final cache = File(
        '${layout.nodesDirectoryPath}/node-a/strategy-cache.json',
      );
      final provisional = json.decode(await cache.readAsString()) as Map;
      runtime
        ..batchGate = Completer<int?>()
        ..batchFinished = Completer<void>();
      var activationCalls = 0;

      controller.startBackgroundSelection(
        [plan],
        onSelectionChanged: () async {
          activationCalls++;
          return true;
        },
      );
      await Future<void>.delayed(Duration.zero);
      final cancellation = controller.cancelBackgroundSelection();
      runtime.batchGate!.complete(0);
      await runtime.batchFinished!.future.timeout(const Duration(seconds: 1));
      await cancellation;

      expect(activationCalls, 0);
      expect(json.decode(await cache.readAsString()), provisional);
    });

    test('reselects a strategy from a legacy fallback cache', () async {
      final plan = _plan(mode: 'auto', args: '');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );
      await controller.buildRuntimeNodes([plan]);
      final cache =
          File('${layout.nodesDirectoryPath}/node-a/strategy-cache.json');
      final legacyCache = json.decode(await cache.readAsString()) as Map
        ..remove('selectionRevision');
      await cache.writeAsString(json.encode(legacyCache), flush: true);
      await controller.cancelBackgroundSelection();
      runtime.batchResults.add(0);

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(runtime.batchCalls, hasLength(2));
      expect(node['arguments'], containsAllInOrder(['--fake', '1']));
      expect(
        (json.decode(await cache.readAsString()) as Map)['selectionRevision'],
        2,
      );
    });

    test('staging rollback restores the previous configuration', () async {
      final oldPlan = _plan(mode: 'manual', args: '--fake 1');
      final newPlan = _plan(mode: 'manual', args: '--fake 2');
      final config =
          File('${layout.nodesDirectoryPath}/node-a/$byedpiConfigFileName');
      await config.parent.create(recursive: true);
      await config.writeAsString(oldPlan.files.values.single);

      expect(
        await controller.stageRuntimePlan(
          currentPlans: [oldPlan],
          nextPlans: [newPlan],
        ),
        isEmpty,
      );
      expect(await controller.rollbackStagedRuntimePlan(), isEmpty);
      expect(await config.readAsString(), oldPlan.files.values.single);
      expect(runtime.applyCalls, 0);
    });

    test('persists the resolved arguments for cold start', () async {
      final plan = _plan(mode: 'auto', args: '');
      expect(
        await controller.stageRuntimePlan(
          currentPlans: const [],
          nextPlans: [plan],
        ),
        isEmpty,
      );
      await controller.commitStagedRuntimePlan();
      await controller.persistColdStart([plan]);
      final nodes =
          (json.decode(runtime.savedManifest!) as Map)['nodes'] as List;

      expect(nodes, hasLength(1));
      expect(
        (nodes.single as Map)['arguments'],
        containsAllInOrder(_defaultFallbackArgs),
      );
    });
  });
}

const _defaultFallbackArgs = <String>[
  '-n',
  'google.com',
  '-Qr',
  '-f-204',
  '-s1:5+sm',
  '-a1',
  '-As',
  '-d1',
  '-s3+s',
  '-s5+s',
  '-q7',
  '-a1',
  '-As',
  '-o2',
  '-f-43',
  '-a1',
  '-As',
  '-r5',
  '-Mh',
  '-s1:5+s',
  '-s3:7+sm',
  '-a1',
];

BuiltInProxyNodePlan _plan({
  required String mode,
  required String args,
  int timeout = 1,
  int foregroundTimeout = 15,
  int selectionConcurrency = 4,
  int failureThreshold = 2,
  int cacheTtl = 604800,
  int recheckAfter = 86400,
  List<String>? strategies,
}) =>
    BuiltInProxyNodePlan(
      nodeId: 'node-a',
      name: 'ByeDPI',
      type: BuiltInProxyType.byedpi,
      listenHost: '127.0.0.1',
      listenPort: 35110,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/byedpi/node-a/config.json': json.encode({
          'listenHost': '127.0.0.1',
          'listenPort': 35110,
          'args': args,
          'mode': mode,
          if (strategies == null) 'strategyList': 'byebyeedpi',
          if (strategies != null) 'strategies': strategies,
          'strategyTest': {
            'urls': ['https://example.com'],
            'timeout': timeout,
          },
          'selection': {
            'foreground-timeout': foregroundTimeout,
            'concurrency': selectionConcurrency,
          },
          'cache': {
            'ttl': cacheTtl,
            'recheck-after': recheckAfter,
            'failure-threshold': failureThreshold,
          },
        }),
      },
    );

class _FakeBinaryBridge implements ByedpiBinaryBridge {
  const _FakeBinaryBridge(
    this.layout, {
    this.strategies = '--fake 1\n--disorder 1',
  });
  final ByedpiSharedInstallLayout layout;
  final String strategies;

  @override
  String get bundledReleaseTag => byedpiPinnedReleaseTag;

  @override
  Future<String> loadBundledStrategyList(String assetPath) async => strategies;

  @override
  Future<ByedpiSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
}

class _FakeRuntimeNodeBridge
    implements
        RuntimeNodePlatformBridge,
        RuntimeNodeProbePlatformBridge,
        RuntimeNodeBatchProbePlatformBridge {
  int applyCalls = 0;
  int allocatedPorts = 0;
  String? savedManifest;
  final List<bool> probeResults = [];
  final List<Map<String, dynamic>> probeCalls = [];
  final List<int?> batchResults = [];
  final List<_BatchCall> batchCalls = [];
  void Function()? onBatch;
  Completer<int?>? batchGate;
  Completer<void>? batchFinished;

  @override
  Future<RuntimeNodePlanState> applyPlan(
      List<Map<String, dynamic>> nodes) async {
    applyCalls++;
    return RuntimeNodePlanState(
      generation: applyCalls,
      status: nodes.isEmpty ? 'idle' : 'ready',
      message: '',
      nodes: nodes,
      optionalCheckActive: false,
    );
  }

  @override
  Future<void> clearColdStartNodes() async => savedManifest = null;

  @override
  Future<bool> probeNode(Map<String, dynamic> node) async {
    probeCalls.add(node);
    return probeResults.isEmpty ? false : probeResults.removeAt(0);
  }

  @override
  Future<int?> probeNodes(
    List<Map<String, dynamic>> nodes, {
    required int concurrency,
  }) async {
    batchCalls.add(_BatchCall(nodes: nodes, concurrency: concurrency));
    onBatch?.call();
    final result = batchGate == null
        ? (batchResults.isEmpty ? null : batchResults.removeAt(0))
        : await batchGate!.future;
    batchFinished?.complete();
    return result;
  }

  @override
  Future<RuntimeNodePlanState> readPlanState() async =>
      const RuntimeNodePlanState(
        generation: 0,
        status: 'idle',
        message: '',
        nodes: [],
        optionalCheckActive: false,
      );

  @override
  Future<void> saveColdStartNodes(String manifestJson) async {
    savedManifest = manifestJson;
  }

  @override
  Future<void> stopPlan() async {}
}

class _BatchCall {
  const _BatchCall({required this.nodes, required this.concurrency});

  final List<Map<String, dynamic>> nodes;
  final int concurrency;
}
