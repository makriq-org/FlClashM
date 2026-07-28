import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_supervisor.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/stormdns_node_controller.dart';
import 'package:flclashx/product/runtime/stormdns_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StormDNS in the runtime supervisor', () {
    late Directory tempDir;
    late _FakeRuntimeNodeBridge runtime;
    late DefaultBuiltInProxySupervisor supervisor;
    late StormDnsSharedInstallLayout layout;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stormdns-supervisor-');
      layout = StormDnsSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/libstormdns.so',
      );
      runtime = _FakeRuntimeNodeBridge();
      supervisor = DefaultBuiltInProxySupervisor(
        runtime: runtime,
        stormDns: StormDnsNodeController(
          binary: _FakeStormDnsBinaryBridge(layout),
          runtime: runtime,
        ),
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('stages, commits, and starts an always-on node', () async {
      final plan = _plan(activation: NodeActivationMode.always);

      expect(await supervisor.stageRuntimePlan([plan]), isEmpty);
      await supervisor.commitStagedRuntimePlan([plan]);
      expect(supervisor.hasCommittedRuntimePlan, isTrue);

      expect(await supervisor.start(), isTrue);
      final applied = runtime.appliedPlans.last;
      expect(applied.single['type'], 'stormdns');
      expect(applied.single.containsKey('closeStdin'), isFalse);
    });

    test('a reserve node with auto activation stays out of the process plan',
        () async {
      final plan = _plan(activation: NodeActivationMode.auto);

      expect(await supervisor.stageRuntimePlan([plan]), isEmpty);
      await supervisor.commitStagedRuntimePlan([plan]);
      expect(await supervisor.start(), isTrue);

      expect(
        runtime.appliedPlans.last,
        isEmpty,
        reason: 'a sleeping reserve must not be launched',
      );
    });

    test('selecting the reserve node wakes it', () async {
      final plan = _plan(activation: NodeActivationMode.auto);
      await supervisor.stageRuntimePlan([plan]);
      await supervisor.commitStagedRuntimePlan([plan]);
      await supervisor.start();

      await supervisor.notifyProxySelected('Reserve', 'Storm');

      expect(runtime.appliedPlans.last.single['type'], 'stormdns');
    });

    test('artifacts land on disk only once the plan is staged', () async {
      final plan = _plan(activation: NodeActivationMode.always);
      final config = File('${layout.nodesDirectoryPath}/${plan.nodeId}/'
          '$stormDnsConfigFileName');
      expect(config.existsSync(), isFalse);

      await supervisor.stageRuntimePlan([plan]);
      expect(config.existsSync(), isTrue);

      expect(await supervisor.rollbackStagedRuntimePlan(), isEmpty);
      expect(config.existsSync(), isFalse);
    });
  });
}

BuiltInProxyNodePlan _plan({required NodeActivationMode activation}) =>
    BuiltInProxyNodePlan(
      nodeId: 'stormdns-node',
      name: 'Storm',
      type: BuiltInProxyType.stormdns,
      listenHost: '127.0.0.1',
      listenPort: 36200,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      activation: NodeActivationConfig(
        mode: activation,
        wakeUrls: [Uri.parse('https://example.com/generate_204')],
        watchGroup: 'Reserve',
        containingGroups: const ['Reserve'],
      ),
      files: const {
        'built-in-proxies/stormdns/stormdns-node/$stormDnsConfigFileName':
            'LISTEN_PORT = 36200\n',
        'built-in-proxies/stormdns/stormdns-node/'
            '$stormDnsResolversTemplateFileName': '8.8.8.8\n',
      },
      metadata: const {
        'cache-fingerprint': 'fp1',
        'cache-directory': '$stormDnsCacheDirectoryName/fp1',
        'depends-on-system-dns': 'false',
      },
    );

class _FakeStormDnsBinaryBridge implements StormDnsBinaryBridge {
  const _FakeStormDnsBinaryBridge(this.layout);

  final StormDnsSharedInstallLayout layout;

  @override
  Future<StormDnsSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  final List<List<Map<String, dynamic>>> appliedPlans = [];

  @override
  Future<RuntimeNodePlanState> applyPlan(
    List<Map<String, dynamic>> nodes,
  ) async {
    appliedPlans.add(nodes);
    return RuntimeNodePlanState(
      generation: appliedPlans.length,
      status: nodes.isEmpty ? 'idle' : 'ready',
      message: '',
      nodes: const [],
      optionalCheckActive: false,
    );
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
  Future<void> stopPlan() async {}

  @override
  Future<void> saveColdStartNodes(String manifestJson) async {}

  @override
  Future<void> clearColdStartNodes() async {}
}
