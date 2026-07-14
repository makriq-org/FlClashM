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

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('byedpi-controller-');
      layout = ByedpiSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/libbyedpi.so',
      );
      runtime = _FakeRuntimeNodeBridge();
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(layout),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.probeCalls.length,
        now: () => DateTime.utc(2026, 1, 1),
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

    test('uses a persisted fallback for automatic mode', () async {
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
      expect(first['arguments'], containsAllInOrder(['--disorder', '1']));
      expect(cache.existsSync(), isTrue);
      expect((json.decode(await cache.readAsString()) as Map)['strategy'],
          isNotEmpty);
    });

    test('selects and caches the first strategy that passes a native probe',
        () async {
      runtime.probeResults.addAll([false, true]);
      final plan = _plan(mode: 'auto', args: '');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final first = (await controller.buildRuntimeNodes([plan])).single;
      final probeCount = runtime.probeCalls.length;
      final second = (await controller.buildRuntimeNodes([plan])).single;

      expect(runtime.probeCalls, hasLength(2));
      expect(probeCount, 2);
      expect(first['arguments'], containsAllInOrder(['--disorder', '1']));
      expect(second['arguments'], first['arguments']);
      expect(
        (runtime.probeCalls.singleWhere(
          (node) => (node['arguments'] as List).contains('--disorder'),
        )['connectivityCheck'] as Map)['required'],
        isTrue,
      );
    });

    test('checks the full strategy list with the configured timeout', () async {
      runtime.probeResults.addAll([false, false, false, false, true]);
      controller = ByedpiNodeController(
        binary: _FakeBinaryBridge(
          layout,
          strategies: List.generate(
            5,
            (index) => '--strategy ${index + 1}',
          ).join('\n'),
        ),
        runtime: runtime,
        allocateProbePort: () async => 39800 + runtime.probeCalls.length,
        now: () => DateTime.utc(2026, 1, 1),
      );
      final plan = _plan(mode: 'auto', args: '', timeout: 5);
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(runtime.probeCalls, hasLength(5));
      expect(node['arguments'], containsAllInOrder(['--strategy', '5']));
      expect(
        runtime.probeCalls
            .map((probe) => (probe['connectivityCheck'] as Map)['timeout']),
        everyElement(5),
      );
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
      runtime.probeResults.add(true);

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(runtime.probeCalls, hasLength(3));
      expect(node['arguments'], containsAllInOrder(['--fake', '1']));
      expect(
        (json.decode(await cache.readAsString()) as Map)['selectionRevision'],
        1,
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
      expect((nodes.single as Map)['arguments'], contains('--disorder'));
    });
  });
}

BuiltInProxyNodePlan _plan({
  required String mode,
  required String args,
  int timeout = 1,
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
          'strategyList': 'byebyeedpi',
          'strategyTest': {
            'urls': ['https://example.com'],
            'timeout': timeout,
          },
          'cache': {'ttl': 604800},
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
    implements RuntimeNodePlatformBridge, RuntimeNodeProbePlatformBridge {
  int applyCalls = 0;
  String? savedManifest;
  final List<bool> probeResults = [];
  final List<Map<String, dynamic>> probeCalls = [];

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
