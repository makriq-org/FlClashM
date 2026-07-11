import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/olcrtc_node_controller.dart';
import 'package:flclashx/product/runtime/olcrtc_release.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('OlcRtcNodeController', () {
    late _FakeOlcRtcBinaryBridge binary;
    late _FakeRuntimeNodeBridge runtime;
    late Directory tempDir;
    late OlcRtcSharedInstallLayout sharedLayout;
    late List<String> waitedListeners;

    OlcRtcNodeController buildController() => OlcRtcNodeController(
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
      required String roomId,
    }) =>
        BuiltInProxyNodePlan(
          nodeId: nodeId,
          name: name,
          type: BuiltInProxyType.olcrtc,
          listenHost: '127.0.0.1',
          listenPort: listenPort,
          protocol: BuiltInProxyProtocol.socks5,
          udp: false,
          files: {
            'built-in-proxies/olcrtc/$nodeId/config.yaml': 'mode: "cnc"\n'
                'room:\n'
                '  id: "$roomId"\n'
                'socks:\n'
                '  host: "127.0.0.1"\n'
                '  port: $listenPort',
          },
        );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flclashm-olcrtc-');
      sharedLayout = OlcRtcSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/olcrtc',
        pendingPath: '${tempDir.path}/olcrtc.pending',
        rollbackPath: '${tempDir.path}/olcrtc.rollback',
        versionPath: '${tempDir.path}/bundled.version',
        pendingVersionPath: '${tempDir.path}/bundled.pending.version',
        bundledAssetPath: 'assets/runtimes/olcrtc/android/arm64-v8a/olcrtc',
      );
      binary = _FakeOlcRtcBinaryBridge(layout: sharedLayout);
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
        roomId: 'room-new',
      );
      final configPath =
          '${sharedLayout.nodesDirectoryPath}/node-a/$olcRtcConfigFileName';
      await Directory('${sharedLayout.nodesDirectoryPath}/node-a')
          .create(recursive: true);
      await File(configPath).writeAsString(currentConfig(roomId: 'room-old'));
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
        currentConfig(roomId: 'room-new'),
      );
    });

    test('rolls staged config back after a later core failure', () async {
      final controller = buildController();
      final plan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        roomId: 'room-new',
      );
      final configPath =
          '${sharedLayout.nodesDirectoryPath}/node-a/$olcRtcConfigFileName';
      await Directory('${sharedLayout.nodesDirectoryPath}/node-a')
          .create(recursive: true);
      await File(configPath).writeAsString(currentConfig(roomId: 'room-old'));
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
        currentConfig(roomId: 'room-old'),
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
        roomId: 'room-old',
      );
      final nextPlan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35011,
        roomId: 'room-new',
      );
      final configPath =
          '${sharedLayout.nodesDirectoryPath}/node-a/$olcRtcConfigFileName';
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
        roomId: 'room-a',
      );
      final planB = buildPlan(
        'Node B',
        nodeId: 'node-b',
        listenPort: 35011,
        roomId: 'room-b',
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
        roomId: 'room-a',
      );
      final planB = buildPlan(
        'Node B',
        nodeId: 'node-b',
        listenPort: 35011,
        roomId: 'room-b',
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
      expect(runtime.startArguments, [
        [path.join(sharedLayout.nodesDirectoryPath, 'node-a', 'config.yaml')],
        [path.join(sharedLayout.nodesDirectoryPath, 'node-b', 'config.yaml')],
      ]);
      expect(runtime.stopCalls, ['node-a', 'node-b']);
      expect(
        Directory(path.join(path.dirname(sharedLayout.executablePath), 'data'))
            .existsSync(),
        isFalse,
        reason: 'OlcRTC uses embedded dictionaries when overrides are absent',
      );
    });

    test('keeps each node config in its own working directory', () {
      final controller = buildController();

      final nodeA = controller.resolveNodeLayout(sharedLayout, 'node-a');
      final nodeB = controller.resolveNodeLayout(sharedLayout, 'node-b');

      expect(
        nodeA.workingDirectoryPath,
        path.join(sharedLayout.nodesDirectoryPath, 'node-a'),
      );
      expect(nodeA.configPath,
          path.join(nodeA.workingDirectoryPath, 'config.yaml'));
      expect(
        nodeB.workingDirectoryPath,
        path.join(sharedLayout.nodesDirectoryPath, 'node-b'),
      );
      expect(nodeB.configPath,
          path.join(nodeB.workingDirectoryPath, 'config.yaml'));
    });

    test('creates runtime directories during pending update check', () async {
      final controller = buildController();

      await controller.applyPendingUpdate();

      expect(Directory(sharedLayout.runtimeRootPath).existsSync(), isTrue);
      expect(Directory(sharedLayout.nodesDirectoryPath).existsSync(), isTrue);
      expect(File(sharedLayout.executablePath).existsSync(), isFalse);
    });

    test('persists cold-start manifest and clears it for empty plans',
        () async {
      final controller = buildController();
      final plan = buildPlan(
        'Node A',
        nodeId: 'node-a',
        listenPort: 35010,
        roomId: 'room-a',
      );

      await controller.persistColdStart([plan]);
      expect(runtime.savedManifest, isNotNull);
      final manifest = json.decode(runtime.savedManifest!) as Map;
      final nodes = manifest['nodes'] as List;
      expect(nodes.single['arguments'], [
        path.join(sharedLayout.nodesDirectoryPath, 'node-a', 'config.yaml'),
      ]);
      expect(runtime.clearColdStartCalls, 0);

      await controller.persistColdStart(const []);
      expect(runtime.clearColdStartCalls, 1);
    });
  });
}

String currentConfig({required String roomId, int listenPort = 35010}) =>
    'mode: "cnc"\n'
    'room:\n'
    '  id: "$roomId"\n'
    'socks:\n'
    '  host: "127.0.0.1"\n'
    '  port: $listenPort';

class _FakeOlcRtcBinaryBridge implements OlcRtcBinaryBridge {
  _FakeOlcRtcBinaryBridge({
    required this.layout,
  });

  final OlcRtcSharedInstallLayout layout;

  @override
  String get bundledReleaseTag => olcRtcPinnedReleaseTag;

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async =>
      Uint8List.fromList('bundled-binary'.codeUnits);
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  final Map<String, DateTime> runningNodes = {};
  final List<String> startCalls = [];
  final List<List<String>> startArguments = [];
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
    startArguments.add(arguments);
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
