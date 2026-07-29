import 'dart:convert';
import 'dart:io';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flclashx/product/compile/built_in_proxy_normalizer.dart';
import 'package:flclashx/product/compile/byedpi_strategy_sources.dart';
import 'package:flclashx/product/compile/remote_text_list_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  const compiler = BuiltInProxyCompiler();
  const normalizer = BuiltInProxyNormalizer();

  test('canonical duration strings compile to native units', () {
    final result = compiler.compile(
      rawConfig: {
        'proxies': [
          {
            'name': 'Naive',
            'type': 'naiveproxy',
            'server': 'example.com',
            'port': 443,
            'username': 'user',
            'password': 'pass',
            'tunnel-timeout': '10m',
            'idle-timeout': '5m',
            'connectivity-check': {
              'timeout': '5s',
              'startup-timeout': '30s',
              'retry-interval': '1s',
            },
          },
        ],
      },
      patchConfig: const ClashConfig(),
    );
    final native = jsonDecode(result.nodes.single.files.values.single) as Map;
    expect(native['tunnel-timeout'], 600);
    expect(native['idle-timeout'], 300);
  });

  test('legacy aliases normalize once and collisions are rejected', () {
    final legacy = normalizer.normalize({
      'name': 'Bye',
      'type': 'byedpi',
      'mode': 'auto',
      'strategy-list': 'byebyeedpi',
      'strategy-test': {'resolver': 'system', 'concurrency': 2},
      'selection': {
        'concurrency': 3,
        'foreground_timeout': 15,
        'background': false,
      },
      'fallback_args': '--disorder 1',
      'cache': {
        'ttl': 604800,
        'recheck_after': 86400,
        'retry_after': 300,
        'failure_threshold': 2,
      },
    });
    expect(legacy['strategies'], ['builtin:byebyeedpi']);
    expect((legacy['strategy-test'] as Map)['dns-resolver'], 'system');
    expect(
      (legacy['strategy-selection'] as Map)['fallback-strategy'],
      '--disorder 1',
    );
    expect(
      () => normalizer.normalize({
        'name': 'Bye',
        'type': 'byedpi',
        'mode': 'manual',
        'args': '--disorder 1',
        'strategy': '--split 1',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => normalizer.normalize({
        'name': 'Storm',
        'type': 'stormdns',
        'encryption-key': 'a',
        'encryption_key': 'b',
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('field aliases do not rewrite user-defined HTTP header names', () {
    final normalized = normalizer.normalize({
      'name': 'Naive',
      'type': 'naiveproxy',
      'headers': {'X_Custom_Header': 'value'},
    });
    expect(normalized['headers'], {'X_Custom_Header': 'value'});
  });

  test('remote-list discovery ignores ordinary Mihomo proxies', () {
    final config = {
      'proxies': [
        {
          'name': 'VLESS',
          'type': 'vless',
          'custom-options': {'field-name': 1, 'field_name': 2},
        },
      ],
    };
    expect(compiler.collectStormDnsRemoteLists(config), isEmpty);
    expect(compiler.collectByedpiRemoteLists(config), isEmpty);
  });

  test('second-based runtime fields reject lossy sub-second values', () {
    expect(
      () => compiler.compile(
        rawConfig: {
          'proxies': [
            {
              'name': 'Naive',
              'type': 'naiveproxy',
              'server': 'example.com',
              'port': 443,
              'username': 'user',
              'password': 'pass',
              'connectivity-check': {'timeout': '500ms'},
            },
          ],
        },
        patchConfig: const ClashConfig(),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('ByeDPI combines builtin, inline and remote sources in order', () {
    final url = Uri.parse('https://example.org/strategies.txt');
    final result = compiler.compile(
      rawConfig: {
        'proxies': [
          {
            'name': 'Bye',
            'type': 'byedpi',
            'mode': 'auto',
            'strategies': [
              'builtin:byebyeedpi',
              '--disorder 1',
              url.toString(),
              '--disorder 1',
            ],
            'strategy-selection': {
              'startup-timeout': '15s',
              'retry-after': '5m',
              'cache': {'ttl': '7d', 'recheck-after': '1d'},
            },
          },
        ],
      },
      patchConfig: const ClashConfig(),
      byedpiRemoteLists: {
        url: ByedpiRemoteStrategyList(
          strategies: const ['--split 1', '--disorder 1'],
          fetchedAt: DateTime.utc(2026),
        ),
      },
    );
    final native = jsonDecode(result.nodes.single.files.values.single) as Map;
    expect(native['strategies'], [
      'builtin:byebyeedpi',
      '--disorder 1',
      '--split 1',
    ]);
    expect((native['selection'] as Map)['foreground-timeout'], 15);
    expect((native['cache'] as Map)['retry-after'], 300);
    expect((native['cache'] as Map)['ttl'], 604800);
  });

  test('remote strategy parser validates every effective line', () {
    const parser = ByedpiStrategySourceParser();
    final url = Uri.parse('https://example.org/list.txt');
    expect(
      parser.parseRemoteBody(
        '# comment\n\n--disorder 1\n--split 1\n',
        url,
      ),
      ['--disorder 1', '--split 1'],
    );
    expect(
      () => parser.parseRemoteBody('--daemon\n', url),
      throwsA(isA<FormatException>()),
    );
  });

  test('ByeDPI strategy sources are safe during the validation pass', () {
    for (final source in const [
      'builtin:unknown',
      'https://127.0.0.1/strategies.txt',
    ]) {
      expect(
        () => compiler.validateConfig({
          'proxies': [
            {
              'name': 'Bye',
              'type': 'byedpi',
              'strategies': [source],
            },
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('remote text store serves a stale copy after a failed refresh',
      () async {
    final directory = await Directory.systemTemp.createTemp('remote-list-');
    addTearDown(() => directory.delete(recursive: true));
    final url = Uri.parse('https://example.org/list.txt');
    var now = DateTime.utc(2026);
    var body = '--disorder 1';
    final store = RemoteTextListStore(
      cacheDirectoryPath: directory.path,
      now: () => now,
      download: (_, {required timeout}) async => body,
    );
    expect(
      (await store.resolve([url], refresh: const Duration(days: 1)))[url]!.body,
      body,
    );
    now = now.add(const Duration(days: 2));
    body = '';
    final offline = RemoteTextListStore(
      cacheDirectoryPath: directory.path,
      now: () => now,
      download: (_, {required timeout}) async => null,
    );
    expect(
      (await offline.resolve([url], refresh: const Duration(days: 1)))[url]!
          .body,
      '--disorder 1',
    );
  });

  test('OlcRTC canonical transport options compile to upstream YAML', () {
    final result = compiler.compile(
      rawConfig: {
        'proxies': [
          {
            'name': 'RTC',
            'type': 'olcrtc',
            'activation': 'always',
            'provider': 'jitsi',
            'room': 'https://meet.example.org/room',
            'room-channel': 'default',
            'encryption-key': _key,
            'transport': 'seichannel',
            'dns-server': '1.1.1.1:53',
            'transport-options': {
              'fps': 30,
              'batch-size': 64,
              'fragment-size': 900,
              'ack-timeout': '2s',
            },
            'lifecycle': {'max-session-duration': '1d'},
          },
        ],
      },
      patchConfig: const ClashConfig(),
    );
    final yaml = result.nodes.single.files.values.single;
    expect(yaml, contains('provider: "jitsi"'));
    expect(yaml, contains('ack_timeout_ms: 2000'));
    expect(yaml, contains('max_session_duration: "24h"'));
    expect(yaml, isNot(contains('transport-options')));
  });

  test('OlcRTC keeps video bitrate and owns the disabled hardware mode', () {
    final result = compiler.compile(
      rawConfig: {
        'proxies': [
          {
            'name': 'RTC',
            'type': 'olcrtc',
            'activation': 'always',
            'provider': 'jitsi',
            'room': 'https://meet.example.org/room',
            'encryption-key': _key,
            'transport': 'videochannel',
            'dns-server': '1.1.1.1:53',
            'transport-options': {
              'width': 1920,
              'height': 1080,
              'fps': 30,
              'bitrate': '2M',
            },
          },
        ],
      },
      patchConfig: const ClashConfig(),
    );
    final yaml = result.nodes.single.files.values.single;
    expect(yaml, contains('bitrate: "2M"'));
    expect(yaml, contains('hw: "none"'));
  });

  test('OlcRTC enforces provider and transport cross-field rules', () {
    Map<String, dynamic> node() => {
          'name': 'RTC',
          'type': 'olcrtc',
          'activation': 'always',
          'provider': 'jitsi',
          'room': 'room',
          'encryption-key': _key,
          'transport': 'datachannel',
          'dns-server': '1.1.1.1:53',
        };
    expect(
      () => compiler.compile(
        rawConfig: {
          'proxies': [
            node()..['transport-options'] = {'fps': 30},
          ],
        },
        patchConfig: const ClashConfig(),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => compiler.compile(
        rawConfig: {
          'proxies': [
            node()
              ..['engine'] = 'jitsi'
              ..['engine-url'] = 'https://meet.example.org'
              ..['engine-token'] = 'token',
          ],
        },
        patchConfig: const ClashConfig(),
      ),
      throwsA(isA<FormatException>()),
    );
    for (final removed in ['profiles', 'failover']) {
      expect(
        () => compiler.compile(
          rawConfig: {
            'proxies': [
              node()..[removed] = removed == 'profiles' ? [] : {},
            ],
          },
          patchConfig: const ClashConfig(),
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
