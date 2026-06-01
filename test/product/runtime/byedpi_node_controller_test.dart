import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashm/product/android/android_runtime_node_bridge.dart';
import 'package:flclashm/product/runtime/built_in_proxy_types.dart';
import 'package:flclashm/product/runtime/byedpi_node_controller.dart';
import 'package:flclashm/product/runtime/byedpi_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ByedpiNodeController', () {
    late Directory tempDir;
    late ByedpiSharedInstallLayout sharedLayout;
    late _FakeByedpiBinaryBridge binary;
    late _FakeRuntimeNodeBridge runtime;
    late List<bool> checkResults;

    ByedpiNodeController buildController() => ByedpiNodeController(
          binary: binary,
          runtime: runtime,
          waitForListener: (_, __) async {},
          siteCheck: ({
            required host,
            required port,
            required url,
            required timeout,
          }) async =>
              checkResults.isEmpty ? true : checkResults.removeAt(0),
          now: () => DateTime(2026, 6, 1, 12),
        );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flclashm-byedpi-');
      sharedLayout = ByedpiSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/ciadpi',
        pendingPath: '${tempDir.path}/ciadpi.pending',
        rollbackPath: '${tempDir.path}/ciadpi.rollback',
        versionPath: '${tempDir.path}/bundled.version',
        pendingVersionPath: '${tempDir.path}/bundled.pending.version',
        bundledAssetPath: 'assets/runtimes/byedpi/android/arm64-v8a/ciadpi',
      );
      binary = _FakeByedpiBinaryBridge(layout: sharedLayout);
      runtime = _FakeRuntimeNodeBridge();
      checkResults = <bool>[];
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('starts manual nodes with client-owned ip and port arguments',
        () async {
      final controller = buildController();
      final plan = _buildManualPlan();

      expect(
        await controller.stageRuntimePlan(
          currentPlans: const [],
          nextPlans: [plan],
        ),
        isEmpty,
      );
      await controller.commitStagedRuntimePlan();

      expect(await controller.startNodes([plan]), isTrue);
      expect(runtime.startArguments.single, [
        '--ip',
        '127.0.0.1',
        '--port',
        '35610',
        '--disorder',
        '1',
        '--auto=torst',
      ]);
    });

    test('selects and caches the first working auto strategy', () async {
      final controller = buildController();
      final plan = _buildAutoPlan();
      checkResults.addAll([false, true]);

      expect(
        await controller.stageRuntimePlan(
          currentPlans: const [],
          nextPlans: [plan],
        ),
        isEmpty,
      );
      await controller.commitStagedRuntimePlan();

      expect(await controller.startNodes([plan]), isTrue);

      expect(runtime.startArguments, [
        ['--ip', '127.0.0.1', '--port', '35610', '--fake', '-1'],
        ['--ip', '127.0.0.1', '--port', '35610', '--disorder', '1'],
      ]);
      final cache = File('${sharedLayout.nodesDirectoryPath}/byedpi-a/'
          'strategy-cache.json');
      expect(cache.existsSync(), isTrue);
      expect(
          json.decode(await cache.readAsString())['strategy'], '--disorder 1');
    });

    test('checks auto strategy URLs with configured concurrency', () async {
      var activeChecks = 0;
      var maxActiveChecks = 0;
      final controller = ByedpiNodeController(
        binary: binary,
        runtime: runtime,
        waitForListener: (_, __) async {},
        siteCheck: ({
          required host,
          required port,
          required url,
          required timeout,
        }) async {
          activeChecks++;
          if (activeChecks > maxActiveChecks) {
            maxActiveChecks = activeChecks;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
          activeChecks--;
          return true;
        },
        now: () => DateTime(2026, 6, 1, 12),
      );
      final plan = _buildAutoPlan(requests: 4, concurrency: 2);

      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );
      await controller.commitStagedRuntimePlan();

      expect(await controller.startNodes([plan]), isTrue);
      expect(maxActiveChecks, 2);
    });

    test('persists cached auto strategy for cold start', () async {
      final controller = buildController();
      final plan = _buildAutoPlan();
      checkResults.add(true);

      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );
      await controller.commitStagedRuntimePlan();
      expect(await controller.startNodes([plan]), isTrue);
      await controller.persistColdStart([plan]);

      final manifest = json.decode(runtime.savedManifest!) as Map;
      final node = (manifest['nodes'] as List).single as Map;
      expect(node['arguments'], [
        '--ip',
        '127.0.0.1',
        '--port',
        '35610',
        '--fake',
        '-1',
      ]);
    });
  });
}

BuiltInProxyNodePlan _buildManualPlan() => BuiltInProxyNodePlan(
      nodeId: 'byedpi-a',
      name: 'ByeDPI',
      type: BuiltInProxyType.byedpi,
      listenHost: '127.0.0.1',
      listenPort: 35610,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/byedpi/byedpi-a/config.json': json.encode({
          'mode': 'manual',
          'listenHost': '127.0.0.1',
          'listenPort': 35610,
          'args': '--disorder 1 --auto=torst',
          'cache': {},
        }),
      },
    );

BuiltInProxyNodePlan _buildAutoPlan({
  int requests = 1,
  int? concurrency,
}) =>
    BuiltInProxyNodePlan(
      nodeId: 'byedpi-a',
      name: 'ByeDPI',
      type: BuiltInProxyType.byedpi,
      listenHost: '127.0.0.1',
      listenPort: 35610,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/byedpi/byedpi-a/config.json': json.encode({
          'mode': 'auto',
          'listenHost': '127.0.0.1',
          'listenPort': 35610,
          'strategies': ['--fake -1', '--disorder 1'],
          'test': {
            'urls': ['https://example.com/'],
            'timeout': 5,
            'requests': requests,
            if (concurrency != null) 'concurrency': concurrency,
          },
          'cache': {},
        }),
      },
    );

class _FakeByedpiBinaryBridge implements ByedpiBinaryBridge {
  const _FakeByedpiBinaryBridge({required this.layout});

  final ByedpiSharedInstallLayout layout;

  @override
  String get bundledReleaseTag => byedpiPinnedReleaseTag;

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async =>
      Uint8List.fromList('byedpi'.codeUnits);

  @override
  Future<String> loadBundledStrategyList(String assetPath) async =>
      '--fake -1\n--disorder 1\n';

  @override
  Future<ByedpiSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  final Map<String, DateTime> runningNodes = {};
  final List<List<String>> startArguments = [];
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
    List<String> arguments = const [],
  }) async {
    startArguments.add(arguments);
    final result = startResults.isEmpty ? true : startResults.removeAt(0);
    if (!result) {
      return false;
    }
    runningNodes[nodeId] = DateTime(2026, 6, 1, 12);
    return true;
  }

  @override
  Future<void> stopNode({required String nodeId}) async {
    runningNodes.remove(nodeId);
  }
}
