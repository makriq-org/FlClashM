import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compiler = BuiltInProxyCompiler();

  BuiltInProxyNodePlan compile(
    Map<String, dynamic> config, {
    String globalUrl = '',
  }) {
    final result = compiler.compile(
      rawConfig: config,
      patchConfig: const ClashConfig(),
      globalTestUrl: globalUrl,
    );
    return result.nodes.single;
  }

  test('parses all connectivity-check fields', () {
    final plan = compile({
      'proxies': [
        {
          ..._naive,
          'connectivity-check': {
            'urls': ['https://example.org/generate_204'],
            'required': true,
            'timeout': 6,
            'startup-timeout': 31,
            'retry-interval': 2,
            'requests': 3,
            'concurrency': 2,
            'min-success-ratio': 0.5,
          },
        },
      ],
    });

    expect(plan.connectivityCheck.urls.single.host, 'example.org');
    expect(plan.connectivityCheck.required, isTrue);
    expect(plan.connectivityCheck.timeout, const Duration(seconds: 6));
    expect(plan.connectivityCheck.startupTimeout, const Duration(seconds: 31));
    expect(plan.connectivityCheck.retryInterval, const Duration(seconds: 2));
    expect(plan.connectivityCheck.requests, 3);
    expect(plan.connectivityCheck.concurrency, 2);
    expect(plan.connectivityCheck.minSuccessRatio, 0.5);
  });

  test('applies the common contract to NaiveProxy, OlcRTC and ByeDPI', () {
    const check = <String, dynamic>{
      'urls': ['https://example.org/generate_204'],
      'required': true,
    };
    final result = compiler.compile(
      rawConfig: {
        'proxies': [
          {..._naive, 'connectivity-check': check},
          {
            'name': 'OlcRTC',
            'type': 'olcrtc',
            'auth': {'provider': 'jitsi'},
            'room': {'id': 'https://meet.example.org/room'},
            'crypto': {
              'key':
                  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            },
            'net': {'transport': 'datachannel', 'dns': '8.8.8.8:53'},
            'connectivity-check': check,
          },
          {
            'name': 'ByeDPI',
            'type': 'byedpi',
            'mode': 'manual',
            'args': '--disorder 1',
            'connectivity-check': check,
          },
        ],
      },
      patchConfig: const ClashConfig(),
    );

    expect(result.nodes.map((node) => node.type).toSet(), {
      BuiltInProxyType.naiveproxy,
      BuiltInProxyType.olcrtc,
      BuiltInProxyType.byedpi,
    });
    expect(
      result.nodes.every((node) => node.connectivityCheck.required),
      isTrue,
    );
  });

  test('uses defaults and inherits the nearest containing group address', () {
    final plan = compile({
      'proxies': [_naive],
      'proxy-groups': [
        {
          'name': 'Inner',
          'type': 'select',
          'proxies': ['Naive'],
          'connectivity-check': {
            'urls': ['https://inner.example/'],
          },
        },
        {
          'name': 'Outer',
          'type': 'url-test',
          'proxies': ['Inner'],
          'url': 'https://outer.example/',
        },
      ],
    });

    expect(plan.connectivityCheck.urls.single.host, 'inner.example');
    expect(plan.connectivityCheck.required, isFalse);
    expect(plan.connectivityCheck.timeout, const Duration(seconds: 5));
    expect(plan.connectivityCheck.startupTimeout, const Duration(seconds: 30));
    expect(plan.connectivityCheck.retryInterval, const Duration(seconds: 1));
    expect(plan.connectivityCheck.requests, 1);
    expect(plan.connectivityCheck.concurrency, 1);
    expect(plan.connectivityCheck.minSuccessRatio, isNull);
  });

  test('walks parent groups and then uses the application address', () {
    final fromParent = compile({
      'proxies': [_naive],
      'proxy-groups': [
        {
          'name': 'Inner',
          'type': 'select',
          'proxies': ['Naive']
        },
        {
          'name': 'Outer',
          'type': 'url-test',
          'proxies': ['Inner'],
          'url': 'https://outer.example/check',
        },
      ],
    });
    expect(fromParent.connectivityCheck.urls.single.host, 'outer.example');

    final fromApplication = compile(
      {
        'proxies': [_naive],
      },
      globalUrl: 'https://app.example/generate_204',
    );
    expect(fromApplication.connectivityCheck.urls.single.host, 'app.example');
  });

  test('keeps only process and port checks when no address exists', () {
    final plan = compile({
      'proxies': [_naive],
    });
    expect(plan.connectivityCheck.urls, isEmpty);
  });

  test('rejects required checks without an inherited address', () {
    expect(
      () => compile({
        'proxies': [
          {
            ..._naive,
            'connectivity-check': {'required': true},
          },
        ],
      }),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('requires a connectivity-check address'),
      )),
    );
  });

  test('rejects unsafe addresses and excessive work', () {
    for (final unsafe in [
      'ftp://example.org/',
      'https://user:secret@example.org/',
      'http://localhost/',
      'http://localhost./',
      'http://127.0.0.1/',
      'http://10.0.0.1/',
      'http://[::1]/',
      'http://198.51.100.1/',
      'http://203.0.113.1/',
      'https://example.org:0/',
      'https://example.org:99999/',
    ]) {
      expect(
        () => compile({
          'proxies': [
            {
              ..._naive,
              'connectivity-check': {
                'urls': [unsafe],
              },
            },
          ],
        }),
        throwsA(isA<FormatException>()),
        reason: unsafe,
      );
    }
    for (final field in {
      'timeout': 61,
      'startup-timeout': 301,
      'retry-interval': 0,
      'requests': 33,
      'concurrency': 17,
      'min-success-ratio': 1.1,
    }.entries) {
      expect(
        () => compile({
          'proxies': [
            {
              ..._naive,
              'connectivity-check': {
                'urls': ['https://example.org/'],
                field.key: field.value,
              },
            },
          ],
        }),
        throwsA(isA<FormatException>()),
        reason: field.key,
      );
    }
  });

  test('separates ByeDPI strategy-test and rejects legacy test', () {
    final plan = compile({
      'proxies': [
        {
          'name': 'ByeDPI',
          'type': 'byedpi',
          'mode': 'auto',
          'strategies': ['--fake 1'],
          'strategy-test': {
            'urls': ['https://strategy.example/'],
          },
          'connectivity-check': {
            'urls': ['https://connectivity.example/'],
          },
        },
      ],
    });
    expect(plan.connectivityCheck.urls.single.host, 'connectivity.example');

    expect(
      () => compile({
        'proxies': [
          {
            'name': 'ByeDPI',
            'type': 'byedpi',
            'mode': 'auto',
            'strategies': ['--fake 1'],
            'test': {
              'urls': ['https://example.org/'],
            },
          },
        ],
      }),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('Rename it to `strategy-test`'),
      )),
    );
  });
}

const _naive = <String, dynamic>{
  'name': 'Naive',
  'type': 'naiveproxy',
  'proxy': 'https://user:pass@example.com',
};
