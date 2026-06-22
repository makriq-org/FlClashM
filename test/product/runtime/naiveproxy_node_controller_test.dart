import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/naiveproxy_node_controller.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NaiveProxyNodeController', () {
    late _FakeNaiveProxyBinaryBridge binary;
    late _FakeRuntimeNodeBridge runtime;
    late Directory tempDir;
    late NaiveProxySharedInstallLayout sharedLayout;
    late List<String> waitedListeners;

    NaiveProxyNodeController buildController() => NaiveProxyNodeController(
          binary: binary,
          runtime: runtime,
          waitForListener: (host, port) async {
            waitedListeners.add('$host:$port');
          },
        );

    BuiltInProxyNodePlan buildPlan(
      String name, {
      required String nodeId,
      required int listenPort,
      required String upstreamProxy,
    }) =>
        BuiltInProxyNodePlan(
          nodeId: nodeId,
          name: name,
          type: BuiltInProxyType.naiveproxy,
          listenHost: '127.0.0.1',
          listenPort: listenPort,
          protocol: BuiltInProxyProtocol.socks5,
          udp: false,
          files: {
            'built-in-proxies/naiveproxy/$nodeId/config.json': json.encode(
              {
                'listen': 'socks://127.0.0.1:$listenPort',
                'proxy': upstreamProxy,
              },
            ),
          },
        );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flclashm-naiveproxy-');
      sharedLayout = NaiveProxySharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/naiveproxy',
        pendingPath: '${tempDir.path}/naiveproxy.pending',
        rollbackPath: '${tempDir.path}/naiveproxy.rollback',
        versionPath: '${tempDir.path}/bundled.version',
        pendingVersionPath: '${tempDir.path}/bundled.pending.version',
        bundledAssetPath:
            'assets/runtimes/naiveproxy/android/arm64-v8a/libnaive.so',
      );
      binary = _FakeNaiveProxyBinaryBridge(layout: sharedLayout);
      runtime = _FakeRuntimeNodeBridge();
      waitedListeners = <String>[];
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('stages updated config and restarts a running node', () async {
      final controller = buildController();
      final plan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        upstreamProxy: 'https://new.example',
      );
      final configPath =
          '${sharedLayout.nodesDirectoryPath}/node-a/$naiveProxyConfigFileName';
      await Directory('${sharedLayout.nodesDirectoryPath}/node-a')
          .create(recursive: true);
      await File(configPath).writeAsString(
        '{"listen":"socks://127.0.0.1:35010","proxy":"https://old.example"}',
      );
      runtime.runningNodes['node-a'] = DateTime(2026, 5, 1, 2, 3, 4);

      final message = await controller.stageRuntimePlan(
        currentPlans: [plan],
        nextPlans: [plan],
      );

      expect(message, isEmpty);
      expect(runtime.stopCalls, ['node-a']);
      expect(runtime.startCalls, ['node-a']);
      expect(
        await File(configPath).readAsString(),
        '{"listen":"socks://127.0.0.1:35010","proxy":"https://new.example"}',
      );
    });

    test('rolls staged config back after a later core failure', () async {
      final controller = buildController();
      final plan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        upstreamProxy: 'https://new.example',
      );
      final configPath =
          '${sharedLayout.nodesDirectoryPath}/node-a/$naiveProxyConfigFileName';
      await Directory('${sharedLayout.nodesDirectoryPath}/node-a')
          .create(recursive: true);
      await File(configPath).writeAsString(
        '{"listen":"socks://127.0.0.1:35010","proxy":"https://old.example"}',
      );
      runtime.runningNodes['node-a'] = DateTime(2026, 5, 1, 2, 3, 4);

      final stageMessage = await controller.stageRuntimePlan(
        currentPlans: [plan],
        nextPlans: [plan],
      );
      final rollbackMessage = await controller.rollbackStagedRuntimePlan();

      expect(stageMessage, isEmpty);
      expect(rollbackMessage, isEmpty);
      expect(
        await File(configPath).readAsString(),
        '{"listen":"socks://127.0.0.1:35010","proxy":"https://old.example"}',
      );
      expect(runtime.startCalls, ['node-a', 'node-a']);
      expect(runtime.stopCalls, ['node-a', 'node-a']);
    });

    test('restores previous config and listener when staged restart fails',
        () async {
      final controller = buildController();
      final currentPlan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        upstreamProxy: 'https://old.example',
      );
      final nextPlan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35011,
        upstreamProxy: 'https://new.example',
      );
      final configPath =
          '${sharedLayout.nodesDirectoryPath}/node-a/$naiveProxyConfigFileName';
      await Directory('${sharedLayout.nodesDirectoryPath}/node-a')
          .create(recursive: true);
      await File(configPath).writeAsString(currentPlan.files.values.single);
      runtime.runningNodes['node-a'] = DateTime(2026, 5, 1, 2, 3, 4);
      runtime.startResults.addAll([false, true]);

      final message = await controller.stageRuntimePlan(
        currentPlans: [currentPlan],
        nextPlans: [nextPlan],
      );

      expect(message, contains('failed to restart after config update'));
      expect(await File(configPath).readAsString(),
          currentPlan.files.values.single);
      expect(runtime.startCalls, ['node-a', 'node-a']);
      expect(runtime.stopCalls, ['node-a', 'node-a']);
      expect(waitedListeners, ['127.0.0.1:35010']);
      expect(runtime.runningNodes['node-a'], isNotNull);
    });

    test('commit removes dropped node runtime directories', () async {
      final controller = buildController();
      final planA = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        upstreamProxy: 'https://a.example',
      );
      final planB = buildPlan(
        'Node B',
        nodeId: 'node-b',
        listenPort: 35011,
        upstreamProxy: 'https://b.example',
      );
      await Directory('${sharedLayout.nodesDirectoryPath}/node-a')
          .create(recursive: true);
      await Directory('${sharedLayout.nodesDirectoryPath}/node-b')
          .create(recursive: true);
      runtime.runningNodes['node-b'] = DateTime(2026, 5, 1, 2, 3, 4);

      final stageMessage = await controller.stageRuntimePlan(
        currentPlans: [planA, planB],
        nextPlans: [planA],
      );
      await controller.commitStagedRuntimePlan();

      expect(stageMessage, isEmpty);
      expect(runtime.stopCalls, ['node-b']);
      expect(
          Directory('${sharedLayout.nodesDirectoryPath}/node-b').existsSync(),
          isFalse);
    });

    test('starts and stops multiple nodes independently', () async {
      final controller = buildController();
      final planA = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        upstreamProxy: 'https://a.example',
      );
      final planB = buildPlan(
        'Node B',
        nodeId: 'node-b',
        listenPort: 35011,
        upstreamProxy: 'https://b.example',
      );
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [planA, planB],
      );
      await controller.commitStagedRuntimePlan();

      final started = await controller.startNodes([planA, planB]);
      await controller.stopNodes([planA, planB]);

      expect(started, isTrue);
      expect(runtime.startCalls, ['node-a', 'node-b']);
      expect(runtime.stopCalls, ['node-a', 'node-b']);
    });

    test(
        'installs and swaps shared bundled binaries through pending activation',
        () async {
      final controller = buildController();
      final active = File(sharedLayout.executablePath);
      final pending = File(sharedLayout.pendingPath);

      await controller.applyPendingUpdate();
      expect(await active.readAsString(), 'bundled-binary');

      await active.writeAsString('old-binary');
      await pending.writeAsString('new-binary');
      await File(sharedLayout.pendingVersionPath).writeAsString('external-tag');

      await controller.applyPendingUpdate();

      expect(await active.readAsString(), 'new-binary');
      expect(pending.existsSync(), isFalse);
      expect(
          await File(sharedLayout.versionPath).readAsString(), 'external-tag');
    });

    test('persists cold-start manifest and clears it for empty plans',
        () async {
      final controller = buildController();
      final plan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        upstreamProxy: 'https://a.example',
      );

      await controller.persistColdStart([plan]);
      expect(runtime.savedManifest, isNotNull);
      expect(runtime.clearColdStartCalls, 0);

      await controller.persistColdStart(const []);
      expect(runtime.clearColdStartCalls, 1);
    });
  });
}

class _FakeNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  _FakeNaiveProxyBinaryBridge({
    required this.layout,
  });

  final NaiveProxySharedInstallLayout layout;

  @override
  String get bundledReleaseTag => naiveProxyPinnedReleaseTag;

  @override
  Future<NaiveProxySharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async =>
      Uint8List.fromList('bundled-binary'.codeUnits);
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  final Map<String, DateTime> runningNodes = {};
  final List<String> startCalls = [];
  final List<String> stopCalls = [];
  final List<bool> startResults = [];
  String? savedManifest;
  int clearColdStartCalls = 0;

  @override
  Future<void> clearColdStartNodes() async {
    clearColdStartCalls++;
    savedManifest = null;
  }

  @override
  Future<DateTime?> readNodeStartTime({
    required String nodeId,
  }) async =>
      runningNodes[nodeId];

  @override
  Future<void> saveColdStartNodes(String manifestJson) async {
    savedManifest = manifestJson;
  }

  @override
  Future<bool> startNode({
    required String nodeId,
    required String executablePath,
    required String workingDirectory,
    List<String> arguments = const [],
  }) async {
    startCalls.add(nodeId);
    final result = startResults.isEmpty ? true : startResults.removeAt(0);
    if (!result) {
      return false;
    }
    runningNodes[nodeId] = DateTime(2026, 5, 1, 2, 3, 4);
    return true;
  }

  @override
  Future<void> stopNode({
    required String nodeId,
  }) async {
    stopCalls.add(nodeId);
    runningNodes.remove(nodeId);
  }
}
