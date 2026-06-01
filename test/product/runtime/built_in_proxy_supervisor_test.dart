import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashm/product/android/android_runtime_node_bridge.dart';
import 'package:flclashm/product/runtime/built_in_proxy_supervisor.dart';
import 'package:flclashm/product/runtime/built_in_proxy_types.dart';
import 'package:flclashm/product/runtime/naiveproxy_node_controller.dart';
import 'package:flclashm/product/runtime/naiveproxy_release.dart';
import 'package:flclashm/product/runtime/olcrtc_node_controller.dart';
import 'package:flclashm/product/runtime/olcrtc_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DefaultBuiltInProxySupervisor', () {
    late Directory tempDir;
    late _FakeRuntimeNodeBridge runtime;
    late NaiveProxySharedInstallLayout naiveLayout;
    late OlcRtcSharedInstallLayout olcLayout;

    DefaultBuiltInProxySupervisor buildSupervisor() =>
        DefaultBuiltInProxySupervisor(
          naiveProxy: NaiveProxyNodeController(
            binary: _FakeNaiveProxyBinaryBridge(layout: naiveLayout),
            runtime: runtime,
            waitForListener: (_, __) async {},
          ),
          olcRtc: OlcRtcNodeController(
            binary: _FakeOlcRtcBinaryBridge(layout: olcLayout),
            runtime: runtime,
            waitForListener: (_, __) async {},
          ),
        );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flclashm-supervisor-');
      runtime = _FakeRuntimeNodeBridge();
      naiveLayout = NaiveProxySharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: '${tempDir.path}/naiveproxy',
        nodesDirectoryPath: '${tempDir.path}/naiveproxy/nodes',
        executablePath: '${tempDir.path}/naiveproxy/naiveproxy',
        pendingPath: '${tempDir.path}/naiveproxy/naiveproxy.pending',
        rollbackPath: '${tempDir.path}/naiveproxy/naiveproxy.rollback',
        versionPath: '${tempDir.path}/naiveproxy/bundled.version',
        pendingVersionPath:
            '${tempDir.path}/naiveproxy/bundled.pending.version',
        bundledAssetPath:
            'assets/runtimes/naiveproxy/android/arm64-v8a/libnaive.so',
      );
      olcLayout = OlcRtcSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: '${tempDir.path}/olcrtc',
        nodesDirectoryPath: '${tempDir.path}/olcrtc/nodes',
        executablePath: '${tempDir.path}/olcrtc/olcrtc',
        pendingPath: '${tempDir.path}/olcrtc/olcrtc.pending',
        rollbackPath: '${tempDir.path}/olcrtc/olcrtc.rollback',
        versionPath: '${tempDir.path}/olcrtc/bundled.version',
        pendingVersionPath: '${tempDir.path}/olcrtc/bundled.pending.version',
        bundledAssetPath: 'assets/runtimes/olcrtc/android/arm64-v8a/olcrtc',
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('starts and stops naiveproxy and olcrtc nodes together', () async {
      final supervisor = buildSupervisor();
      final naivePlan = _buildNaivePlan();
      final olcPlan = _buildOlcPlan();

      expect(await supervisor.stageRuntimePlan([naivePlan, olcPlan]), isEmpty);
      await supervisor.commitStagedRuntimePlan([naivePlan, olcPlan]);

      expect(await supervisor.start(), isTrue);
      await supervisor.stop();

      expect(runtime.startCalls, ['naive-a', 'olc-a']);
      expect(runtime.stopCalls, ['olc-a', 'naive-a']);
    });

    test('persists a combined cold-start manifest', () async {
      final supervisor = buildSupervisor();
      final naivePlan = _buildNaivePlan();
      final olcPlan = _buildOlcPlan();

      expect(await supervisor.stageRuntimePlan([naivePlan, olcPlan]), isEmpty);
      await supervisor.commitStagedRuntimePlan([naivePlan, olcPlan]);
      await supervisor.persistColdStart();

      final manifest = json.decode(runtime.savedManifest!) as Map;
      final nodes = manifest['nodes'] as List;
      expect(nodes.map((node) => node['type']), ['naiveproxy', 'olcrtc']);
    });

    test('rolls naiveproxy stage back when olcrtc stage fails', () async {
      final supervisor = buildSupervisor();
      final currentNaive = _buildNaivePlan(proxy: 'https://old.example');
      final nextNaive = _buildNaivePlan(proxy: 'https://new.example');
      final currentOlc = _buildOlcPlan(room: 'old-room');
      final nextOlc = _buildOlcPlan(room: 'new-room');

      final naiveConfigPath =
          '${naiveLayout.nodesDirectoryPath}/naive-a/$naiveProxyConfigFileName';
      final olcConfigPath =
          '${olcLayout.nodesDirectoryPath}/olc-a/$olcRtcConfigFileName';
      await Directory('${naiveLayout.nodesDirectoryPath}/naive-a')
          .create(recursive: true);
      await Directory('${olcLayout.nodesDirectoryPath}/olc-a')
          .create(recursive: true);
      await File(naiveConfigPath).writeAsString(
        currentNaive.files.values.single,
      );
      await File(olcConfigPath).writeAsString(currentOlc.files.values.single);
      runtime.runningNodes['naive-a'] = DateTime(2026, 1, 1);
      runtime.runningNodes['olc-a'] = DateTime(2026, 1, 1);
      runtime.startResults.addAll([true, false, true]);

      final message = await supervisor.stageRuntimePlan(
        [nextNaive, nextOlc],
      );

      expect(message, contains('olcrtc node `OLC` failed to restart'));
      expect(await File(naiveConfigPath).readAsString(),
          currentNaive.files.values.single);
      expect(await File(olcConfigPath).readAsString(),
          currentOlc.files.values.single);
    });
  });
}

BuiltInProxyNodePlan _buildNaivePlan({
  String proxy = 'https://example.com',
}) =>
    BuiltInProxyNodePlan(
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
          'proxy': proxy,
        }),
      },
    );

BuiltInProxyNodePlan _buildOlcPlan({
  String room = 'room-a',
}) =>
    BuiltInProxyNodePlan(
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
            '  id: "$room"\n'
            'socks:\n'
            '  host: "127.0.0.1"\n'
            '  port: 35910',
      },
    );

class _FakeNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  const _FakeNaiveProxyBinaryBridge({required this.layout});

  final NaiveProxySharedInstallLayout layout;

  @override
  String get bundledReleaseTag => naiveProxyPinnedReleaseTag;

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async =>
      Uint8List.fromList('naive'.codeUnits);

  @override
  Future<NaiveProxySharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
}

class _FakeOlcRtcBinaryBridge implements OlcRtcBinaryBridge {
  const _FakeOlcRtcBinaryBridge({required this.layout});

  final OlcRtcSharedInstallLayout layout;

  @override
  String get bundledReleaseTag => olcRtcPinnedReleaseTag;

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async =>
      Uint8List.fromList('olcrtc'.codeUnits);

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  final Map<String, DateTime> runningNodes = {};
  final List<String> startCalls = [];
  final List<String> stopCalls = [];
  final List<bool> startResults = [];
  String? savedManifest;

  @override
  Future<void> clearColdStartNodes() async {
    savedManifest = null;
  }

  @override
  Future<DateTime?> readNodeStartTime({required String nodeId}) async =>
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
  }) async {
    startCalls.add(nodeId);
    final result = startResults.isEmpty ? true : startResults.removeAt(0);
    if (!result) {
      return false;
    }
    runningNodes[nodeId] = DateTime(2026, 1, 1);
    return true;
  }

  @override
  Future<void> stopNode({required String nodeId}) async {
    stopCalls.add(nodeId);
    runningNodes.remove(nodeId);
  }
}
