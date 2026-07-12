import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/byedpi_node_controller.dart';
import 'package:flclashx/product/runtime/byedpi_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ByedpiNodeController', () {
    late Directory tempDir;
    late ByedpiSharedInstallLayout sharedLayout;
    late _FakeByedpiBinaryBridge binary;
    late _FakeRuntimeNodeBridge runtime;
    late List<bool> checkResults;
    late int nextProbePort;

    ByedpiNodeController buildController() => ByedpiNodeController(
          binary: binary,
          runtime: runtime,
          waitForListener: (_, __) async {},
          allocateProbePort: () async => nextProbePort++,
          siteCheck: ({
            required host,
            required port,
            required url,
            required timeout,
          }) async =>
              checkResults.isEmpty ? true : checkResults.removeAt(0),
          now: () => DateTime(2026, 6, 1, 12),
        );

    ByedpiNodeController buildControllerWithDefaultSiteCheck() =>
        ByedpiNodeController(
          binary: binary,
          runtime: runtime,
          waitForListener: (_, __) async {},
          allocateProbePort: () async => nextProbePort++,
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
      nextProbePort = 45610;
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
        ['--ip', '127.0.0.1', '--port', '45610', '--fake', '-1'],
        ['--ip', '127.0.0.1', '--port', '45611', '--disorder', '1'],
        ['--ip', '127.0.0.1', '--port', '35610', '--disorder', '1'],
      ]);
      expect(runtime.runningNodes.keys, ['byedpi-a']);
      expect(runtime.stoppedNodeIds, [
        'byedpi-a-probe-66b26ed526a75edec7b122545e5aea12',
        'byedpi-a-probe-50f8c09d8c922a6a5677208a7742918d',
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
        allocateProbePort: () async => nextProbePort++,
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

    test('starts bundled fallback when auto strategy check fails', () async {
      final controller = buildController();
      final plan = _buildAutoPlan();
      checkResults.addAll([false, false]);

      await controller.stageRuntimePlan(
        currentPlans: const [],
        nextPlans: [plan],
      );
      await controller.commitStagedRuntimePlan();

      expect(await controller.startNodes([plan]), isTrue);
      expect(runtime.runningNodes.keys, ['byedpi-a']);
      expect(runtime.startArguments.last, [
        '--ip',
        '127.0.0.1',
        '--port',
        '35610',
        '--disorder',
        '1',
        '--auto=torst',
        '--tlsrec',
        '1+s',
      ]);

      final cache = File('${sharedLayout.nodesDirectoryPath}/byedpi-a/'
          'strategy-cache.json');
      expect(
        json.decode(await cache.readAsString())['strategy'],
        '--disorder 1 --auto=torst --tlsrec 1+s',
      );
    });

    test('does not treat empty connect as working https strategy', () async {
      final controller = buildControllerWithDefaultSiteCheck();
      final server = await _FakeSocksServer.bind(
        afterConnect: (client, reader) async {
          client.destroy();
        },
      );
      addTearDown(server.close);

      final passed = await controller.siteCheck(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        url: Uri.parse('https://93.184.216.34/'),
        timeout: const Duration(seconds: 1),
      );

      expect(passed, isFalse);
    });

    test('treats valid http response through socks as working strategy',
        () async {
      final controller = buildControllerWithDefaultSiteCheck();
      final server = await _FakeSocksServer.bind(
        afterConnect: (client, reader) async {
          final request = await reader.readHeaders(
            timeout: const Duration(seconds: 1),
            maxLength: 4096,
          );
          expect(request, contains('HEAD / HTTP/1.1'));
          expect(request, contains('Host: 93.184.216.34'));
          client.add(
            utf8.encode(
              'HTTP/1.1 204 No Content\r\n'
              'Content-Length: 0\r\n'
              'Connection: close\r\n'
              '\r\n',
            ),
          );
          await client.flush();
        },
      );
      addTearDown(server.close);

      final passed = await controller.siteCheck(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        url: Uri.parse('http://93.184.216.34/'),
        timeout: const Duration(seconds: 1),
      );

      expect(passed, isTrue);
    });

    test('treats 5xx http response through socks as working strategy',
        () async {
      final controller = buildControllerWithDefaultSiteCheck();
      final server = await _FakeSocksServer.bind(
        afterConnect: (client, reader) async {
          final request = await reader.readHeaders(
            timeout: const Duration(seconds: 1),
            maxLength: 4096,
          );
          expect(request, contains('HEAD / HTTP/1.1'));
          expect(request, contains('Host: 93.184.216.34'));
          client.add(
            utf8.encode(
              'HTTP/1.1 503 Service Unavailable\r\n'
              'Content-Length: 0\r\n'
              'Connection: close\r\n'
              '\r\n',
            ),
          );
          await client.flush();
        },
      );
      addTearDown(server.close);

      final passed = await controller.siteCheck(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        url: Uri.parse('http://93.184.216.34/'),
        timeout: const Duration(seconds: 1),
      );

      expect(passed, isTrue);
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
          'strategyTest': {
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
  final List<String> stoppedNodeIds = [];
  String? savedManifest;

  @override
  Future<void> clearColdStartNodes() async {
    savedManifest = null;
  }

  @override
  Future<DateTime?> readNodeStartTime({required String nodeId}) async =>
      runningNodes[nodeId];

  @override
  Future<String?> readNodeLastError({required String nodeId}) async => null;

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
    stoppedNodeIds.add(nodeId);
    runningNodes.remove(nodeId);
  }
}

class _FakeSocksServer {
  _FakeSocksServer._({
    required ServerSocket server,
    required this.afterConnect,
  }) : _server = server {
    _subscription = _server.listen(_handleClient);
  }

  final ServerSocket _server;
  final Future<void> Function(Socket client, _SocketByteReader reader)
      afterConnect;
  late final StreamSubscription<Socket> _subscription;
  final Set<Socket> _clients = <Socket>{};

  int get port => _server.port;

  static Future<_FakeSocksServer> bind({
    required Future<void> Function(Socket client, _SocketByteReader reader)
        afterConnect,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeSocksServer._(server: server, afterConnect: afterConnect);
  }

  Future<void> close() async {
    await _subscription.cancel();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    await _server.close();
  }

  Future<void> _handleClient(Socket client) async {
    _clients.add(client);
    final reader = _SocketByteReader(client);
    try {
      final greeting = await reader.readBytes(2, const Duration(seconds: 1));
      expect(greeting[0], 0x05);
      await reader.readBytes(greeting[1], const Duration(seconds: 1));
      client.add(const [0x05, 0x00]);
      await client.flush();

      final request = await reader.readBytes(4, const Duration(seconds: 1));
      expect(request[0], 0x05);
      expect(request[1], 0x01);
      expect(request[2], 0x00);
      await _discardSocksAddress(
        reader,
        request[3],
        const Duration(seconds: 1),
      );
      await reader.readBytes(2, const Duration(seconds: 1));

      client.add(const [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 80]);
      await client.flush();
      await afterConnect(client, reader);
    } finally {
      client.destroy();
      _clients.remove(client);
    }
  }

  Future<void> _discardSocksAddress(
    _SocketByteReader reader,
    int addressType,
    Duration timeout,
  ) async {
    switch (addressType) {
      case 0x01:
        await reader.readBytes(4, timeout);
        return;
      case 0x03:
        final length = (await reader.readBytes(1, timeout)).single;
        await reader.readBytes(length, timeout);
        return;
      case 0x04:
        await reader.readBytes(16, timeout);
        return;
      default:
        throw StateError('Unknown SOCKS address type: $addressType');
    }
  }
}

class _SocketByteReader {
  _SocketByteReader(Stream<List<int>> stream)
      : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  List<int> _buffer = <int>[];

  Future<List<int>> readBytes(int length, Duration timeout) async {
    while (_buffer.length < length) {
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) {
        throw const SocketException('Unexpected socket close');
      }
      _buffer.addAll(_iterator.current);
    }
    return _take(length);
  }

  Future<String> readHeaders({
    required Duration timeout,
    required int maxLength,
  }) async {
    const delimiter = [0x0d, 0x0a, 0x0d, 0x0a];
    while (true) {
      final delimiterIndex = _indexOf(delimiter);
      if (delimiterIndex != -1) {
        return latin1.decode(_take(delimiterIndex + delimiter.length));
      }
      if (_buffer.length >= maxLength) {
        throw StateError('HTTP request is too long');
      }
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) {
        throw const SocketException('Unexpected socket close');
      }
      _buffer.addAll(_iterator.current);
    }
  }

  int _indexOf(List<int> pattern) {
    final lastIndex = _buffer.length - pattern.length;
    for (var start = 0; start <= lastIndex; start++) {
      var matches = true;
      for (var offset = 0; offset < pattern.length; offset++) {
        if (_buffer[start + offset] != pattern[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return start;
      }
    }
    return -1;
  }

  List<int> _take(int length) {
    final result = _buffer.sublist(0, length);
    _buffer = length == _buffer.length ? <int>[] : _buffer.sublist(length);
    return result;
  }
}
