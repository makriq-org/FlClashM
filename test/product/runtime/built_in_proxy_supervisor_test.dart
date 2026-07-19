import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_supervisor.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/byedpi_node_controller.dart';
import 'package:flclashx/product/runtime/byedpi_release.dart';
import 'package:flclashx/product/runtime/naiveproxy_node_controller.dart';
import 'package:flclashx/product/runtime/olcrtc_node_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DefaultBuiltInProxySupervisor', () {
    late Directory tempDir;
    late _FakeRuntimeNodeBridge runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('runtime-supervisor-');
      runtime = _FakeRuntimeNodeBridge();
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    DefaultBuiltInProxySupervisor buildSupervisor({
      _ResolveGate? gate,
      String byedpiStrategies = '--fake -1',
      Duration Function()? monotonicNow,
    }) {
      final naiveLayout = NaiveProxySharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: '${tempDir.path}/naiveproxy',
        nodesDirectoryPath: '${tempDir.path}/naiveproxy/nodes',
        executablePath: '${tempDir.path}/libnaive.so',
      );
      final byedpiLayout = ByedpiSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: '${tempDir.path}/byedpi',
        nodesDirectoryPath: '${tempDir.path}/byedpi/nodes',
        executablePath: '${tempDir.path}/libbyedpi.so',
      );
      final olcLayout = OlcRtcSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: '${tempDir.path}/olcrtc',
        nodesDirectoryPath: '${tempDir.path}/olcrtc/nodes',
        executablePath: '${tempDir.path}/libolcrtc.so',
      );
      return DefaultBuiltInProxySupervisor(
        runtime: runtime,
        naiveProxy: NaiveProxyNodeController(
          binary: _FakeNaiveProxyBinaryBridge(naiveLayout, gate),
          runtime: runtime,
        ),
        byedpi: ByedpiNodeController(
          binary: _FakeByedpiBinaryBridge(
            byedpiLayout,
            gate,
            strategies: byedpiStrategies,
          ),
          runtime: runtime,
          allocateProbePort: () async => 39800 + runtime.allocatedPorts++,
          monotonicNow: monotonicNow,
        ),
        olcRtc: OlcRtcNodeController(
          binary: _FakeOlcRtcBinaryBridge(olcLayout, gate),
          runtime: runtime,
        ),
      );
    }

    test('passes every node type to Android in one plan', () async {
      final supervisor = buildSupervisor();
      final plans = [_naivePlan(), _byedpiPlan(), _olcPlan()];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      await supervisor.commitStagedRuntimePlan(plans);

      expect(await supervisor.start(), isTrue);

      expect(runtime.appliedPlans, hasLength(1));
      expect(
        runtime.appliedPlans.single.map((node) => node['type']).toSet(),
        {'naiveproxy', 'byedpi', 'olcrtc'},
      );
    });

    test('prepares independent node types concurrently', () async {
      final gate = _ResolveGate(3);
      final supervisor = buildSupervisor(gate: gate);
      final plans = [_naivePlan(), _byedpiPlan(), _olcPlan()];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      await supervisor.commitStagedRuntimePlan(plans);
      gate.enabled = true;

      final starting = supervisor.start();
      await gate.allEntered.future.timeout(const Duration(seconds: 1));
      expect(runtime.appliedPlans, isEmpty);

      gate.release.complete();
      expect(await starting, isTrue);
      expect(runtime.appliedPlans.single, hasLength(3));
    });

    test('reconnect reapplies one identical plan for Android reuse', () async {
      final supervisor = buildSupervisor();
      final plans = [_naivePlan(), _olcPlan()];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      await supervisor.commitStagedRuntimePlan(plans);

      expect(await supervisor.start(), isTrue);
      expect(await supervisor.start(), isTrue);

      expect(runtime.appliedPlans, hasLength(2));
      expect(runtime.appliedPlans[1], runtime.appliedPlans[0]);
      expect(runtime.generation, 1);
    });

    test('persists one combined cold-start manifest', () async {
      final supervisor = buildSupervisor();
      final plans = [_naivePlan(), _byedpiPlan(), _olcPlan()];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      await supervisor.commitStagedRuntimePlan(plans);

      await supervisor.persistColdStart();

      final manifest = json.decode(runtime.savedManifest!) as Map;
      expect((manifest['nodes'] as List), hasLength(3));
    });

    test('activates a background ByeDPI selection and refreshes cold start',
        () async {
      var elapsed = Duration.zero;
      runtime.onBatch = () {
        if (runtime.batchCalls.length == 1) {
          elapsed += const Duration(seconds: 1);
        }
      };
      final supervisor = buildSupervisor(
        byedpiStrategies: '--strategy 1\n--strategy 2',
        monotonicNow: () => elapsed,
      );
      final plans = [_byedpiAutoPlan()];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      expect((await supervisor.startRuntimePlan(plans)).isSuccess, isTrue);
      runtime.batchResults.add(0);

      await supervisor.commitStagedRuntimePlan(plans);
      await _waitUntil(() => runtime.appliedPlans.length == 2);

      expect(
        runtime.appliedPlans.last.single['arguments'],
        containsAllInOrder(['--strategy', '2']),
      );
      await _waitUntil(() => runtime.savedManifest != null);
      final manifest = json.decode(runtime.savedManifest!) as Map;
      expect(
        ((manifest['nodes'] as List).single as Map)['arguments'],
        containsAllInOrder(['--strategy', '2']),
      );
    });

    test('serializes background activation of multiple ByeDPI nodes', () async {
      var elapsed = Duration.zero;
      runtime.onBatch = () => elapsed += const Duration(seconds: 1);
      final supervisor = buildSupervisor(
        byedpiStrategies: '--strategy 1\n--strategy 2',
        monotonicNow: () => elapsed,
      );
      final plans = [
        _byedpiAutoPlan(),
        _byedpiAutoPlan(nodeId: 'byedpi-auto-b', port: 35112),
      ];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      expect((await supervisor.startRuntimePlan(plans)).isSuccess, isTrue);
      runtime
        ..batchResults.addAll([0, 0])
        ..applyGate = Completer<void>();

      await supervisor.commitStagedRuntimePlan(plans);
      await _waitUntil(() => runtime.activeApplyCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(runtime.maximumActiveApplyCalls, 1);
      runtime.applyGate!.complete();
      await _waitUntil(() => runtime.appliedPlans.length == 3);
    });

    test('does not apply a background strategy after a new plan is staged',
        () async {
      var elapsed = Duration.zero;
      final gate = _ResolveGate(1);
      runtime.onBatch = () {
        if (runtime.batchCalls.length == 1) {
          elapsed += const Duration(seconds: 1);
        } else {
          gate.enabled = true;
        }
      };
      final supervisor = buildSupervisor(
        gate: gate,
        byedpiStrategies: '--strategy 1\n--strategy 2',
        monotonicNow: () => elapsed,
      );
      final plans = [_byedpiAutoPlan()];
      expect(await supervisor.stageRuntimePlan(plans), isEmpty);
      expect((await supervisor.startRuntimePlan(plans)).isSuccess, isTrue);
      runtime.batchResults.add(0);

      await supervisor.commitStagedRuntimePlan(plans);
      await gate.allEntered.future.timeout(const Duration(seconds: 1));
      final staging = supervisor.stageRuntimePlan([_byedpiPlan()]);
      await Future<void>.delayed(Duration.zero);
      gate.release.complete();
      expect(
        await staging.timeout(const Duration(seconds: 1)),
        isEmpty,
      );
      await Future<void>.delayed(Duration.zero);

      expect(runtime.appliedPlans, hasLength(1));
    });
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

BuiltInProxyNodePlan _naivePlan() => BuiltInProxyNodePlan(
      nodeId: 'naive-a',
      name: 'Naive',
      type: BuiltInProxyType.naiveproxy,
      listenHost: '127.0.0.1',
      listenPort: 35010,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/naiveproxy/naive-a/config.json': json.encode({
          'listen': 'socks://127.0.0.1:35010',
          'proxy': 'https://example.com',
        }),
      },
    );

BuiltInProxyNodePlan _byedpiPlan() => BuiltInProxyNodePlan(
      nodeId: 'byedpi-a',
      name: 'ByeDPI',
      type: BuiltInProxyType.byedpi,
      listenHost: '127.0.0.1',
      listenPort: 35110,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/byedpi/byedpi-a/config.json': json.encode({
          'listenHost': '127.0.0.1',
          'listenPort': 35110,
          'args': '--fake -1',
          'mode': 'manual',
        }),
      },
    );

BuiltInProxyNodePlan _byedpiAutoPlan({
  String nodeId = 'byedpi-auto',
  int port = 35111,
}) =>
    BuiltInProxyNodePlan(
      nodeId: nodeId,
      name: 'ByeDPI Auto',
      type: BuiltInProxyType.byedpi,
      listenHost: '127.0.0.1',
      listenPort: port,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/byedpi/$nodeId/config.json': json.encode({
          'listenHost': '127.0.0.1',
          'listenPort': port,
          'mode': 'auto',
          'strategyList': 'byebyeedpi',
          'strategyTest': {
            'urls': ['https://example.com'],
            'timeout': 1,
          },
          'selection': {
            'foreground-timeout': 1,
            'concurrency': 1,
          },
          'cache': {'ttl': 604800},
        }),
      },
    );

BuiltInProxyNodePlan _olcPlan() => const BuiltInProxyNodePlan(
      nodeId: 'olc-a',
      name: 'OLC',
      type: BuiltInProxyType.olcrtc,
      listenHost: '127.0.0.1',
      listenPort: 35910,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/olcrtc/olc-a/config.yaml': 'mode: "cnc"\n'
            'room:\n'
            '  id: "room-a"\n'
            'socks:\n'
            '  host: "127.0.0.1"\n'
            '  port: 35910',
      },
    );

class _ResolveGate {
  _ResolveGate(this.expected);

  final int expected;
  final Completer<void> allEntered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool enabled = false;
  int entered = 0;

  Future<void> enter() async {
    if (!enabled) return;
    entered++;
    if (entered == expected) allEntered.complete();
    await release.future;
  }
}

class _FakeNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  const _FakeNaiveProxyBinaryBridge(this.layout, this.gate);
  final NaiveProxySharedInstallLayout layout;
  final _ResolveGate? gate;

  @override
  Future<NaiveProxySharedInstallLayout> resolveSharedInstallLayout() async {
    await gate?.enter();
    return layout;
  }
}

class _FakeByedpiBinaryBridge implements ByedpiBinaryBridge {
  const _FakeByedpiBinaryBridge(
    this.layout,
    this.gate, {
    required this.strategies,
  });
  final ByedpiSharedInstallLayout layout;
  final _ResolveGate? gate;
  final String strategies;

  @override
  String get bundledReleaseTag => byedpiPinnedReleaseTag;

  @override
  Future<String> loadBundledStrategyList(String assetPath) async => strategies;

  @override
  Future<ByedpiSharedInstallLayout> resolveSharedInstallLayout() async {
    await gate?.enter();
    return layout;
  }
}

class _FakeOlcRtcBinaryBridge implements OlcRtcBinaryBridge {
  const _FakeOlcRtcBinaryBridge(this.layout, this.gate);
  final OlcRtcSharedInstallLayout layout;
  final _ResolveGate? gate;

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async {
    await gate?.enter();
    return layout;
  }
}

class _FakeRuntimeNodeBridge
    implements RuntimeNodePlatformBridge, RuntimeNodeBatchProbePlatformBridge {
  final List<List<Map<String, dynamic>>> appliedPlans = [];
  final List<_SupervisorBatchCall> batchCalls = [];
  final List<int?> batchResults = [];
  int generation = 0;
  int allocatedPorts = 0;
  int activeApplyCalls = 0;
  int maximumActiveApplyCalls = 0;
  String? savedManifest;
  void Function()? onBatch;
  Completer<void>? applyGate;

  @override
  Future<RuntimeNodePlanState> applyPlan(
    List<Map<String, dynamic>> nodes,
  ) async {
    activeApplyCalls++;
    if (activeApplyCalls > maximumActiveApplyCalls) {
      maximumActiveApplyCalls = activeApplyCalls;
    }
    try {
      await applyGate?.future;
      final snapshot = [
        for (final node in nodes) Map<String, dynamic>.from(node)
      ];
      if (appliedPlans.isEmpty ||
          appliedPlans.last.toString() != snapshot.toString()) {
        generation++;
      }
      appliedPlans.add(snapshot);
      return RuntimeNodePlanState(
        generation: generation,
        status: nodes.isEmpty ? 'idle' : 'ready',
        message: '',
        nodes: snapshot,
        optionalCheckActive: false,
      );
    } finally {
      activeApplyCalls--;
    }
  }

  @override
  Future<void> clearColdStartNodes() async => savedManifest = null;

  @override
  Future<int?> probeNodes(
    List<Map<String, dynamic>> nodes, {
    required int concurrency,
  }) async {
    batchCalls.add(_SupervisorBatchCall(nodes, concurrency));
    onBatch?.call();
    return batchResults.isEmpty ? null : batchResults.removeAt(0);
  }

  @override
  Future<RuntimeNodePlanState> readPlanState() async => RuntimeNodePlanState(
        generation: generation,
        status: 'ready',
        message: '',
        nodes: appliedPlans.lastOrNull ?? const [],
        optionalCheckActive: false,
      );

  @override
  Future<void> saveColdStartNodes(String manifestJson) async {
    savedManifest = manifestJson;
  }

  @override
  Future<void> stopPlan() async {}
}

class _SupervisorBatchCall {
  const _SupervisorBatchCall(this.nodes, this.concurrency);

  final List<Map<String, dynamic>> nodes;
  final int concurrency;
}
