import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/olcrtc_node_controller.dart';
import 'package:flclashx/product/runtime/olcrtc_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OlcRtcNodeController', () {
    late Directory tempDir;
    late OlcRtcSharedInstallLayout layout;
    late _FakeRuntimeNodeBridge runtime;
    late OlcRtcNodeController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('olcrtc-controller-');
      layout = OlcRtcSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/libolcrtc.so',
      );
      runtime = _FakeRuntimeNodeBridge();
      controller = OlcRtcNodeController(
        binary: _FakeBinaryBridge(layout),
        runtime: runtime,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('stages and rolls config back without controlling processes',
        () async {
      final oldPlan = _plan('old-room');
      final newPlan = _plan('new-room');
      final config =
          File('${layout.nodesDirectoryPath}/node-a/$olcRtcConfigFileName');
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
    });

    test('passes the node-specific config path to Android', () async {
      final plan = _plan('room-a');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      final node = (await controller.buildRuntimeNodes([plan])).single;

      expect(node['type'], 'olcrtc');
      expect(node['arguments'], [
        '${layout.nodesDirectoryPath}/node-a/$olcRtcConfigFileName',
      ]);
      expect(node['revision'], hasLength(64));
    });

    test('declares a generic single-DNS artifact for system DNS', () async {
      final plan = _plan('room-a', systemDns: true);
      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );

      final node = (await controller.buildRuntimeNodes([plan])).single;
      expect(node['resolverFile'], {
        'template': olcRtcConfigTemplateFileName,
        'path': olcRtcConfigFileName,
        'dependsOnSystemDns': true,
        'systemDnsMode': 'single-host-port',
      });
      expect(
        await File(
          '${layout.nodesDirectoryPath}/node-a/$olcRtcConfigTemplateFileName',
        ).readAsString(),
        contains(olcRtcSystemDnsPlaceholder),
      );
    });

    test('persists one manifest and clears it for an empty plan', () async {
      await controller.persistColdStart([_plan('room-a')]);
      expect(
          (json.decode(runtime.savedManifest!) as Map)['nodes'], hasLength(1));

      await controller.persistColdStart(const []);
      expect(runtime.savedManifest, isNull);
    });
  });
}

BuiltInProxyNodePlan _plan(String room, {bool systemDns = false}) => BuiltInProxyNodePlan(
      nodeId: 'node-a',
      name: 'OlcRTC',
      type: BuiltInProxyType.olcrtc,
      listenHost: '127.0.0.1',
      listenPort: 35910,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/olcrtc/node-a/config.yaml': 'mode: "cnc"\n'
            'room:\n'
            '  id: "$room"\n'
            '${systemDns ? 'net:\n  dns: "$olcRtcSystemDnsPlaceholder"\n' : ''}'
            'socks:\n'
            '  host: "127.0.0.1"\n'
            '  port: 35910',
      },
      metadata: {'depends-on-system-dns': '$systemDns'},
    );

class _FakeBinaryBridge implements OlcRtcBinaryBridge {
  const _FakeBinaryBridge(this.layout);
  final OlcRtcSharedInstallLayout layout;

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
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
