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

    DefaultBuiltInProxySupervisor buildSupervisor({_ResolveGate? gate}) {
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
          binary: _FakeByedpiBinaryBridge(byedpiLayout, gate),
          runtime: runtime,
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
  });
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
  const _FakeByedpiBinaryBridge(this.layout, this.gate);
  final ByedpiSharedInstallLayout layout;
  final _ResolveGate? gate;

  @override
  String get bundledReleaseTag => byedpiPinnedReleaseTag;

  @override
  Future<String> loadBundledStrategyList(String assetPath) async => '--fake -1';

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

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  final List<List<Map<String, dynamic>>> appliedPlans = [];
  int generation = 0;
  String? savedManifest;

  @override
  Future<RuntimeNodePlanState> applyPlan(
    List<Map<String, dynamic>> nodes,
  ) async {
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
  }

  @override
  Future<void> clearColdStartNodes() async => savedManifest = null;

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
