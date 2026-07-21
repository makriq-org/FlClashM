import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/naiveproxy_node_controller.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NaiveProxyNodeController', () {
    late Directory tempDir;
    late NaiveProxySharedInstallLayout layout;
    late _FakeBinaryBridge binary;
    late _FakeRuntimeNodeBridge runtime;
    late NaiveProxyNodeController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('naive-controller-');
      layout = NaiveProxySharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/libnaive.so',
      );
      binary = _FakeBinaryBridge(layout);
      runtime = _FakeRuntimeNodeBridge();
      controller = NaiveProxyNodeController(
        binary: binary,
        runtime: runtime,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('stages and rolls config back without controlling processes',
        () async {
      final oldPlan = _plan('https://old.example');
      final newPlan = _plan('https://new.example');
      final config =
          File('${layout.nodesDirectoryPath}/node-a/$naiveProxyConfigFileName');
      await config.parent.create(recursive: true);
      await config.writeAsString(oldPlan.files.values.single);

      expect(
        await controller.stageRuntimePlan(
          currentPlans: [oldPlan],
          nextPlans: [newPlan],
        ),
        isEmpty,
      );
      expect(await config.readAsString(), newPlan.files.values.single);
      expect(runtime.applyCalls, 0);

      expect(await controller.rollbackStagedRuntimePlan(), isEmpty);
      expect(await config.readAsString(), oldPlan.files.values.single);
      expect(runtime.applyCalls, 0);
    });

    test('builds complete Android-owned runtime node description', () async {
      final plan = _plan('https://example.com');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(node['nodeId'], 'node-a');
      expect(node['type'], 'naiveproxy');
      expect(node['executablePath'], layout.executablePath);
      expect(node['workingDirectory'], '${layout.nodesDirectoryPath}/node-a');
      expect(node['revision'], hasLength(64));
      expect(node['connectivityCheck'], isA<Map>());
    });

    test('commit removes directories of dropped nodes', () async {
      final plan = _plan('https://example.com');
      final nodeDirectory = Directory('${layout.nodesDirectoryPath}/node-a');
      await nodeDirectory.create(recursive: true);
      await File('${nodeDirectory.path}/unused').writeAsString('x');

      expect(
        await controller
            .stageRuntimePlan(currentPlans: [plan], nextPlans: const []),
        isEmpty,
      );
      await controller.commitStagedRuntimePlan();

      expect(nodeDirectory.existsSync(), isFalse);
    });

    test('cleanup failure does not turn an applied plan into a failure',
        () async {
      final plan = _plan('https://example.com');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: [plan], nextPlans: const []),
        isEmpty,
      );
      binary.failResolve = true;

      await expectLater(controller.commitStagedRuntimePlan(), completes);
    });

    test('persists and clears the cold-start manifest', () async {
      final plan = _plan('https://example.com');
      await controller.persistColdStart([plan]);
      expect(
          (json.decode(runtime.savedManifest!) as Map)['nodes'], hasLength(1));

      await controller.persistColdStart(const []);
      expect(runtime.savedManifest, isNull);
    });

    test('skips empty staging and reuses the stable shared layout', () async {
      expect(
        await controller.stageRuntimePlan(
          currentPlans: const [],
          nextPlans: const [],
        ),
        isEmpty,
      );
      expect(binary.resolveCalls, 0);

      final plan = _plan('https://user:pass@example.com');
      expect(
        await controller.stageRuntimePlan(
          currentPlans: const [],
          nextPlans: [plan],
        ),
        isEmpty,
      );
      await controller.commitStagedRuntimePlan();
      await controller.buildRuntimeNodes([plan]);
      await controller.buildRuntimeNodes([plan]);

      expect(binary.resolveCalls, 1);
    });
  });
}

BuiltInProxyNodePlan _plan(String proxy) => BuiltInProxyNodePlan(
      nodeId: 'node-a',
      name: 'Naive',
      type: BuiltInProxyType.naiveproxy,
      listenHost: '127.0.0.1',
      listenPort: 35010,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/naiveproxy/node-a/config.json': json.encode({
          'listen': 'socks://127.0.0.1:35010',
          'proxy': proxy,
        }),
      },
    );

class _FakeBinaryBridge implements NaiveProxyBinaryBridge {
  _FakeBinaryBridge(this.layout);
  final NaiveProxySharedInstallLayout layout;
  bool failResolve = false;
  int resolveCalls = 0;

  @override
  Future<NaiveProxySharedInstallLayout> resolveSharedInstallLayout() async {
    resolveCalls++;
    if (failResolve) throw const FileSystemException('cleanup failed');
    return layout;
  }
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  int applyCalls = 0;
  String? savedManifest;

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
