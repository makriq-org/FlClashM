import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/runtime/connectivity_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts one success without ratio and enforces an explicit ratio',
      () async {
    final results = <bool>[false, true, false, false];
    final checker = ConnectivityChecker(
      probe: (
              {required host,
              required port,
              required url,
              required timeout}) async =>
          results.removeAt(0),
    );
    final base = ConnectivityCheckConfig(
      urls: [Uri(scheme: 'https', host: 'example.org')],
      requests: 2,
      concurrency: 2,
    );
    expect(await checker.checkOnce(host: '127.0.0.1', port: 1080, config: base),
        isTrue);
    expect(
      await checker.checkOnce(
        host: '127.0.0.1',
        port: 1080,
        config: ConnectivityCheckConfig(
          urls: [Uri(scheme: 'https', host: 'example.org')],
          requests: 2,
          concurrency: 2,
          minSuccessRatio: 0.5,
        ),
      ),
      isFalse,
    );
  });

  test('limits active requests to configured concurrency', () async {
    var active = 0;
    var maximum = 0;
    final checker = ConnectivityChecker(
      probe: (
          {required host,
          required port,
          required url,
          required timeout}) async {
        active++;
        maximum = active > maximum ? active : maximum;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return true;
      },
    );
    await checker.checkOnce(
      host: '127.0.0.1',
      port: 1080,
      config: ConnectivityCheckConfig(
        urls: [Uri(scheme: 'https', host: 'example.org')],
        requests: 6,
        concurrency: 2,
      ),
    );
    expect(maximum, 2);
  });

  test('returns as soon as the required success count is reached', () async {
    final slowProbe = Completer<bool>();
    var attempt = 0;
    final checker = ConnectivityChecker(
      probe: ({required host, required port, required url, required timeout}) {
        attempt++;
        return attempt == 1 ? Future.value(true) : slowProbe.future;
      },
    );

    final result = await checker
        .checkOnce(
          host: '127.0.0.1',
          port: 1080,
          config: ConnectivityCheckConfig(
            urls: [Uri(scheme: 'https', host: 'example.org')],
            requests: 2,
            concurrency: 2,
          ),
        )
        .timeout(const Duration(milliseconds: 100));

    expect(result, isTrue);
    slowProbe.complete(false);
  });

  test('retries a required check and stops when the process exits', () async {
    var attempts = 0;
    final checker = ConnectivityChecker(
      probe: (
          {required host,
          required port,
          required url,
          required timeout}) async {
        attempts++;
        return attempts == 2;
      },
      delay: (_) async {},
    );
    expect(
      await checker.checkUntilDeadline(
        host: '127.0.0.1',
        port: 1080,
        config: ConnectivityCheckConfig(
          urls: [Uri(scheme: 'https', host: 'example.org')],
          startupTimeout: const Duration(seconds: 1),
          retryInterval: const Duration(milliseconds: 1),
        ),
        isProcessRunning: () async => true,
      ),
      isTrue,
    );
    expect(attempts, 2);

    attempts = 0;
    expect(
      await checker.checkUntilDeadline(
        host: '127.0.0.1',
        port: 1080,
        config: ConnectivityCheckConfig(
          urls: [Uri(scheme: 'https', host: 'example.org')],
          startupTimeout: const Duration(seconds: 1),
          retryInterval: const Duration(milliseconds: 1),
        ),
        isProcessRunning: () async => false,
      ),
      isFalse,
    );
    expect(attempts, 0);
  });

  test('sends HTTP strictly through SOCKS and accepts 5xx', () async {
    final server = await _FakeSocksServer.bind(status: 503);
    addTearDown(server.close);

    final passed = await checkUrlViaSocks(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      url: Uri.parse('http://93.184.216.34/check?q=1'),
      timeout: const Duration(seconds: 1),
    );

    expect(passed, isTrue);
    expect(server.requests.single, contains('HEAD /check?q=1 HTTP/1.1'));
    expect(server.requests.single, contains('Host: 93.184.216.34'));
  });

  test('has no direct fallback when SOCKS negotiation fails', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((client) {
      client.add(const [0x05, 0xff]);
      unawaited(client.close());
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close();
    });

    expect(
      await checkUrlViaSocks(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        url: Uri.parse('http://93.184.216.34/'),
        timeout: const Duration(milliseconds: 300),
      ),
      isFalse,
    );
  });

  test('rejects local destinations before opening SOCKS', () async {
    var accepted = false;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((client) {
      accepted = true;
      client.destroy();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close();
    });

    expect(
      await checkUrlViaSocks(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        url: Uri.parse('http://127.0.0.1/'),
        timeout: const Duration(milliseconds: 300),
      ),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(accepted, isFalse);
  });
}

class _FakeSocksServer {
  _FakeSocksServer._(this._server, this.status) {
    _subscription = _server.listen(_handle);
  }

  final ServerSocket _server;
  final int status;
  final requests = <String>[];
  late final StreamSubscription<Socket> _subscription;

  int get port => _server.port;

  static Future<_FakeSocksServer> bind({required int status}) async =>
      _FakeSocksServer._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        status,
      );

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
  }

  Future<void> _handle(Socket client) async {
    final reader = _Reader(client);
    try {
      final greeting = await reader.bytes(3);
      if (greeting[0] != 5) return;
      client.add(const [5, 0]);
      await client.flush();
      final header = await reader.bytes(4);
      final addressLength = switch (header[3]) {
        1 => 4,
        4 => 16,
        _ => (await reader.bytes(1)).single,
      };
      await reader.bytes(addressLength + 2);
      client.add(const [5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
      await client.flush();
      requests.add(await reader.headers());
      client.add(utf8.encode(
        'HTTP/1.1 $status Result\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
      ));
      await client.flush();
    } finally {
      client.destroy();
    }
  }
}

class _Reader {
  _Reader(Stream<List<int>> stream) : iterator = StreamIterator(stream);

  final StreamIterator<List<int>> iterator;
  final buffer = <int>[];

  Future<List<int>> bytes(int length) async {
    while (buffer.length < length) {
      if (!await iterator.moveNext()) throw const SocketException('closed');
      buffer.addAll(iterator.current);
    }
    final result = buffer.sublist(0, length);
    buffer.removeRange(0, length);
    return result;
  }

  Future<String> headers() async {
    while (true) {
      for (var index = 0; index <= buffer.length - 4; index++) {
        if (buffer[index] == 13 &&
            buffer[index + 1] == 10 &&
            buffer[index + 2] == 13 &&
            buffer[index + 3] == 10) {
          return latin1.decode(await bytes(index + 4));
        }
      }
      if (!await iterator.moveNext()) throw const SocketException('closed');
      buffer.addAll(iterator.current);
    }
  }
}
