import 'dart:io';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/stormdns_node_controller.dart';
import 'package:flclashx/product/runtime/stormdns_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StormDnsNodeController', () {
    late Directory tempDir;
    late StormDnsSharedInstallLayout layout;
    late StormDnsNodeController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('stormdns-controller-');
      layout = StormDnsSharedInstallLayout(
        abi: 'arm64-v8a',
        runtimeRootPath: tempDir.path,
        nodesDirectoryPath: '${tempDir.path}/nodes',
        executablePath: '${tempDir.path}/libstormdns.so',
      );
      controller = StormDnsNodeController(
        binary: _FakeBinaryBridge(layout),
        runtime: _FakeRuntimeNodeBridge(),
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    File configFile(String nodeId) =>
        File('${layout.nodesDirectoryPath}/$nodeId/$stormDnsConfigFileName');
    File templateFile(String nodeId) =>
        File('${layout.nodesDirectoryPath}/$nodeId/'
            '$stormDnsResolversTemplateFileName');

    test('stages both artifacts together', () async {
      final plan = _plan(config: 'A', resolvers: '8.8.8.8\n');
      expect(
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]),
        isEmpty,
      );

      expect(await configFile(plan.nodeId).readAsString(), 'A');
      expect(await templateFile(plan.nodeId).readAsString(), '8.8.8.8\n');
    });

    test('rolls both artifacts back to the previous plan', () async {
      final oldPlan = _plan(config: 'OLD', resolvers: 'old\n');
      final newPlan = _plan(config: 'NEW', resolvers: 'new\n');

      await controller
          .stageRuntimePlan(currentPlans: const [], nextPlans: [oldPlan]);
      await controller.commitStagedRuntimePlan();

      expect(
        await controller
            .stageRuntimePlan(currentPlans: [oldPlan], nextPlans: [newPlan]),
        isEmpty,
      );
      expect(await configFile(newPlan.nodeId).readAsString(), 'NEW');
      expect(await templateFile(newPlan.nodeId).readAsString(), 'new\n');

      expect(await controller.rollbackStagedRuntimePlan(), isEmpty);
      expect(await configFile(oldPlan.nodeId).readAsString(), 'OLD');
      expect(
        await templateFile(oldPlan.nodeId).readAsString(),
        'old\n',
        reason: 'the second artifact must roll back with the first',
      );
    });

    test('a resolver-only change still stages and rolls back', () async {
      final oldPlan = _plan(config: 'SAME', resolvers: 'old\n');
      final newPlan = _plan(config: 'SAME', resolvers: 'new\n');

      await controller
          .stageRuntimePlan(currentPlans: const [], nextPlans: [oldPlan]);
      await controller.commitStagedRuntimePlan();

      expect(
        await controller
            .stageRuntimePlan(currentPlans: [oldPlan], nextPlans: [newPlan]),
        isEmpty,
      );
      expect(await templateFile(newPlan.nodeId).readAsString(), 'new\n');

      expect(await controller.rollbackStagedRuntimePlan(), isEmpty);
      expect(await templateFile(oldPlan.nodeId).readAsString(), 'old\n');
    });

    test('rollback of a brand-new node removes the whole directory', () async {
      final plan = _plan(config: 'A', resolvers: 'r\n');
      await controller
          .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]);
      expect(configFile(plan.nodeId).existsSync(), isTrue);

      expect(await controller.rollbackStagedRuntimePlan(), isEmpty);
      expect(
        Directory('${layout.nodesDirectoryPath}/${plan.nodeId}').existsSync(),
        isFalse,
      );
    });

    test('the resolver template change is reflected in the node revision',
        () async {
      final first = _plan(config: 'SAME', resolvers: 'a\n');
      final second = _plan(config: 'SAME', resolvers: 'b\n');
      await controller
          .stageRuntimePlan(currentPlans: const [], nextPlans: [first]);

      final firstNode = (await controller.buildRuntimeNodes([first])).single;
      final secondNode = (await controller.buildRuntimeNodes([second])).single;
      expect(firstNode['revision'], isNot(secondNode['revision']));
    });

    group('working cache', () {
      test('a new fingerprint leaves the old cache in place until commit',
          () async {
        final oldPlan =
            _plan(config: 'A', resolvers: 'a\n', fingerprint: 'old');
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [oldPlan]);
        await controller.commitStagedRuntimePlan();

        final oldCache = Directory(
          '${layout.nodesDirectoryPath}/${oldPlan.nodeId}/'
          '$stormDnsCacheDirectoryName/old',
        )..createSync(recursive: true);
        File('${oldCache.path}/logs.txt').writeAsStringSync('measured');

        final newPlan =
            _plan(config: 'B', resolvers: 'b\n', fingerprint: 'new');
        await controller
            .stageRuntimePlan(currentPlans: [oldPlan], nextPlans: [newPlan]);
        expect(
          oldCache.existsSync(),
          isTrue,
          reason: 'staging must not destroy the cache a rollback needs',
        );

        await controller.rollbackStagedRuntimePlan();
        expect(oldCache.existsSync(), isTrue);
      });

      test('committing a new fingerprint drops superseded caches', () async {
        final oldPlan =
            _plan(config: 'A', resolvers: 'a\n', fingerprint: 'old');
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [oldPlan]);
        await controller.commitStagedRuntimePlan();

        final cacheRoot = Directory(
          '${layout.nodesDirectoryPath}/${oldPlan.nodeId}/'
          '$stormDnsCacheDirectoryName',
        );
        Directory('${cacheRoot.path}/old').createSync(recursive: true);
        Directory('${cacheRoot.path}/new').createSync(recursive: true);

        final newPlan =
            _plan(config: 'B', resolvers: 'b\n', fingerprint: 'new');
        await controller
            .stageRuntimePlan(currentPlans: [oldPlan], nextPlans: [newPlan]);
        await controller.commitStagedRuntimePlan();

        expect(Directory('${cacheRoot.path}/old').existsSync(), isFalse);
        expect(Directory('${cacheRoot.path}/new').existsSync(), isTrue);
      });
    });

    group('launch contract', () {
      test('passes both artifact paths and keeps stdin open', () async {
        final plan = _plan(config: 'A', resolvers: 'r\n');
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]);
        final node = (await controller.buildRuntimeNodes([plan])).single;

        final nodeDir = '${layout.nodesDirectoryPath}/${plan.nodeId}';
        expect(node['type'], 'stormdns');
        expect(node['arguments'], [
          '-config',
          '$nodeDir/$stormDnsConfigFileName',
          '-resolvers',
          '$nodeDir/$stormDnsResolversFileName',
        ]);
        expect(node.containsKey('closeStdin'), isFalse);
      });

      test('declares its resolver file and the caches bound to it', () async {
        final plan = _plan(config: 'A', resolvers: 'r\n', fingerprint: 'fp1');
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]);
        final node = (await controller.buildRuntimeNodes([plan])).single;

        expect(node['resolverFile'], {
          'template': stormDnsResolversTemplateFileName,
          'path': stormDnsResolversFileName,
          'dependsOnSystemDns': true,
          'resetPaths': ['$stormDnsCacheDirectoryName/fp1'],
        });
      });

      test('a node without system DNS does not ask for DNS-change restarts',
          () async {
        final plan = _plan(config: 'A', resolvers: 'r\n', systemDns: false);
        await controller
            .stageRuntimePlan(currentPlans: const [], nextPlans: [plan]);
        final node = (await controller.buildRuntimeNodes([plan])).single;

        expect(
          (node['resolverFile'] as Map)['dependsOnSystemDns'],
          isFalse,
        );
      });
    });

    test('a missing resolver artifact is a hard error', () async {
      const plan = BuiltInProxyNodePlan(
        nodeId: 'stormdns-node',
        name: 'Storm',
        type: BuiltInProxyType.stormdns,
        listenHost: '127.0.0.1',
        listenPort: 36200,
        protocol: BuiltInProxyProtocol.socks5,
        udp: false,
        files: {
          'built-in-proxies/stormdns/stormdns-node/$stormDnsConfigFileName':
              'A',
        },
      );
      expect(
        () => controller.readAdditionalArtifacts(plan),
        throwsA(isA<StateError>()),
      );
    });
  });
}

BuiltInProxyNodePlan _plan({
  required String config,
  required String resolvers,
  String fingerprint = 'fp1',
  bool systemDns = true,
  String nodeId = 'stormdns-node',
}) =>
    BuiltInProxyNodePlan(
      nodeId: nodeId,
      name: 'Storm',
      type: BuiltInProxyType.stormdns,
      listenHost: '127.0.0.1',
      listenPort: 36200,
      protocol: BuiltInProxyProtocol.socks5,
      udp: false,
      files: {
        'built-in-proxies/stormdns/$nodeId/$stormDnsConfigFileName': config,
        'built-in-proxies/stormdns/$nodeId/'
            '$stormDnsResolversTemplateFileName': resolvers,
      },
      metadata: {
        'cache-fingerprint': fingerprint,
        'cache-directory': '$stormDnsCacheDirectoryName/$fingerprint',
        'depends-on-system-dns': '$systemDns',
      },
    );

class _FakeBinaryBridge implements StormDnsBinaryBridge {
  const _FakeBinaryBridge(this.layout);

  final StormDnsSharedInstallLayout layout;

  @override
  Future<StormDnsSharedInstallLayout> resolveSharedInstallLayout() async =>
      layout;
}

class _FakeRuntimeNodeBridge implements RuntimeNodePlatformBridge {
  int applyCalls = 0;

  @override
  Future<RuntimeNodePlanState> applyPlan(
      List<Map<String, dynamic>> nodes) async {
    applyCalls++;
    return const RuntimeNodePlanState(
      generation: 1,
      status: 'ready',
      message: '',
      nodes: [],
      optionalCheckActive: false,
    );
  }

  @override
  Future<RuntimeNodePlanState> readPlanState() async =>
      const RuntimeNodePlanState(
        generation: 1,
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
