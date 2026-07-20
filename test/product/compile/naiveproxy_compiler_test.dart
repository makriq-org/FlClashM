import 'dart:convert';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compiler = BuiltInProxyCompiler();

  group('BuiltInProxyCompiler naiveproxy', () {
    test('builds an authenticated native URI and local SOCKS5 bridge', () {
      final compiled = compiler.compile(
        rawConfig: {
          'proxies': [
            {
              'name': 'Naive',
              'type': 'naiveproxy',
              'server': 'proxy.example.com',
              'port': 8443,
              'username': 'user@name',
              'password': 'p:a/ss',
            },
          ],
        },
        patchConfig: const ClashConfig(),
      );

      final plan = compiled.nodes.single;
      expect(plan.udp, isFalse);
      expect(compiled.config['proxies'].single, {
        'name': 'Naive',
        'type': 'socks5',
        'server': '127.0.0.1',
        'port': plan.listenPort,
        'udp': false,
      });
      final runtimeConfig =
          json.decode(plan.files.values.single) as Map<String, dynamic>;
      expect(
        runtimeConfig,
        {
          'listen': 'socks://127.0.0.1:${plan.listenPort}',
          'proxy': 'https://user%40name:p%3Aa%2Fss@proxy.example.com:8443',
        },
      );
    });

    test('maps supported options to the native NaiveProxy config', () {
      final compiled = compiler.compile(
        rawConfig: {
          'proxies': [
            {
              'name': 'Naive QUIC',
              'type': 'naiveproxy',
              'server': '2001:db8::1',
              'port': 443,
              'username': 'user',
              'password': 'pass',
              'transport': 'quic',
              'udp': false,
              'insecure-concurrency': 2,
              'tunnel-timeout': 601,
              'idle-timeout': 301,
              'post-quantum': false,
              'headers': {
                'X-Naive': 'enabled',
                'User-Agent': 'FlClashM',
              },
              'host-resolver-rules': 'MAP proxy.example.com 203.0.113.1',
            },
          ],
        },
        patchConfig: const ClashConfig(),
      );

      final runtimeConfig =
          json.decode(compiled.nodes.single.files.values.single)
              as Map<String, dynamic>;
      expect(runtimeConfig['proxy'], 'quic://user:pass@[2001:db8::1]:443');
      expect(runtimeConfig['insecure-concurrency'], 2);
      expect(runtimeConfig['tunnel-timeout'], 601);
      expect(runtimeConfig['idle-timeout'], 301);
      expect(runtimeConfig['no-post-quantum'], isTrue);
      expect(
        runtimeConfig['extra-headers'],
        'X-Naive: enabled\r\nUser-Agent: FlClashM',
      );
      expect(
        runtimeConfig['host-resolver-rules'],
        'MAP proxy.example.com 203.0.113.1',
      );
      expect(runtimeConfig, isNot(contains('headers')));
      expect(runtimeConfig, isNot(contains('post-quantum')));
    });

    test('rejects more than four insecure concurrent tunnels', () {
      final node = _validNaiveProxy()..['insecure-concurrency'] = 5;

      expect(
        () => _compileNode(compiler, node),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('integer from 1 to 4'),
          ),
        ),
      );
    });

    test('rejects invalid explicitly configured transports', () {
      for (final transport in <Object>['', 'http', 'socks5', 1]) {
        final node = _validNaiveProxy()..['transport'] = transport;

        expect(
          () => _compileNode(compiler, node),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('must be `https` or `quic`'),
            ),
          ),
          reason: 'transport=$transport',
        );
      }
    });

    test('requires the remote endpoint and non-empty credentials', () {
      for (final entry in <String, Object?>{
        'server': '',
        'port': 0,
        'username': '',
        'password': '   ',
      }.entries) {
        final node = _validNaiveProxy()..[entry.key] = entry.value;

        expect(
          () => _compileNode(compiler, node),
          throwsA(isA<FormatException>()),
          reason: entry.key,
        );
      }
    });

    test('rejects the legacy proxy URI field explicitly', () {
      final node = _validNaiveProxy()
        ..remove('server')
        ..remove('port')
        ..remove('username')
        ..remove('password')
        ..['proxy'] = 'https://user:pass@proxy.example.com';

      expect(
        () => _compileNode(compiler, node),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('`proxy` is not supported'),
          ),
        ),
      );
    });

    test('rejects local bind, diagnostic, chain and unknown fields', () {
      for (final field in const [
        'listen',
        'log',
        'log-net-log',
        'ssl-key-log-file',
        'proxy-chain',
        'resolver-range',
        'unknown',
      ]) {
        final node = _validNaiveProxy()..[field] = 'forbidden';

        expect(
          () => _compileNode(compiler, node),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              allOf(contains('unknown or forbidden fields'), contains(field)),
            ),
          ),
          reason: field,
        );
      }
    });

    test('rejects a proxy chain encoded in server', () {
      final node = _validNaiveProxy()
        ..['server'] = 'first.example.com,https://second.example.com';

      expect(
        () => _compileNode(compiler, node),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('not a URI or proxy chain'),
          ),
        ),
      );
    });

    test('rejects malformed optional native settings', () {
      for (final entry in <String, Object?>{
        'tunnel-timeout': 0,
        'idle-timeout': '300',
        'post-quantum': 'true',
        'headers': ['X-Test: value'],
        'host-resolver-rules': 'MAP example.com 203.0.113.1\nEXCLUDE localhost',
      }.entries) {
        final node = _validNaiveProxy()..[entry.key] = entry.value;

        expect(
          () => _compileNode(compiler, node),
          throwsA(isA<FormatException>()),
          reason: entry.key,
        );
      }
    });

    test('rejects null optional native settings', () {
      for (final field in const [
        'insecure-concurrency',
        'tunnel-timeout',
        'idle-timeout',
        'post-quantum',
        'headers',
        'host-resolver-rules',
      ]) {
        final node = _validNaiveProxy()..[field] = null;

        expect(
          () => _compileNode(compiler, node),
          throwsA(isA<FormatException>()),
          reason: field,
        );
      }
    });

    test('rejects CRLF injection in headers', () {
      final node = _validNaiveProxy()
        ..['headers'] = {'X-Test': 'value\r\nInjected: true'};

      expect(
        () => _compileNode(compiler, node),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

CompiledBuiltInProxyNodes _compileNode(
  BuiltInProxyCompiler compiler,
  Map<String, dynamic> node,
) =>
    compiler.compile(
      rawConfig: {
        'proxies': [node],
      },
      patchConfig: const ClashConfig(),
    );

Map<String, dynamic> _validNaiveProxy() => {
      'name': 'Naive',
      'type': 'naiveproxy',
      'server': 'proxy.example.com',
      'port': 443,
      'username': 'user',
      'password': 'pass',
    };
