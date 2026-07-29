import 'dart:convert';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flclashx/product/compile/profile_compiler.dart';
import 'package:flclashx/product/compile/raw_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compiler = BuiltInProxyCompiler();

  CompiledBuiltInProxyNodes compile(Map<String, dynamic> node) =>
      compiler.compile(
        rawConfig: <String, dynamic>{
          'proxies': [node],
        },
        patchConfig: const ClashConfig(),
      );

  Matcher failsAt(String path, [String? text]) => throwsA(
        isA<FormatException>()
            .having((error) => error.message, 'message', contains(path))
            .having(
              (error) => error.message,
              'detail',
              text == null ? isNotEmpty : contains(text),
            ),
      );

  group('NaiveProxy strict config', () {
    test('accepts the maximal safe pinned config', () {
      final result = compile(<String, dynamic>{
        'name': 'Naive',
        'type': 'naiveproxy',
        'udp': false,
        'server': 'example.com',
        'port': 8443,
        'username': 'user',
        'password': 'pass',
        'transport': 'quic',
        'insecure-concurrency': 4,
        'tunnel-timeout': 3600,
        'idle-timeout': 600,
        'post-quantum': false,
        'headers': {
          'X-Test': 'value',
          'User-Agent': 'FlClashM',
        },
        'host-resolver-rules': 'MAP example.com 203.0.113.10',
        'connectivity-check': {
          'urls': ['https://example.org/generate_204'],
          'required': true,
          'timeout': 60,
          'startup-timeout': 300,
          'retry-interval': 300,
          'requests': 32,
          'concurrency': 16,
          'min-success-ratio': 1.0,
        },
      });

      final config = jsonDecode(result.nodes.single.files.values.single) as Map;
      expect(config['proxy'], 'quic://user:pass@example.com:8443');
      expect(config['insecure-concurrency'], 4);
      expect(config['no-post-quantum'], isTrue);
      expect(
        config['extra-headers'],
        'X-Test: value\r\nUser-Agent: FlClashM',
      );
    });

    test('accepts the minimal config with the default HTTPS transport', () {
      final result = compile(<String, dynamic>{
        ..._naive,
      });

      // Dart's Uri omits the default HTTPS port, and naive treats a missing
      // port as 443, so the compiled URI carries no explicit port.
      final config = jsonDecode(result.nodes.single.files.values.single) as Map;
      expect(config['proxy'], 'https://user:pass@example.com');
    });

    test('rejects invalid header names, values, and types', () {
      for (final headers in <Object?>[
        {'Bad Name': 'value'},
        {'X-Test': 'value\r\nInjected: true'},
        {'X-Test': 'value\nInjected: true'},
        {'X-Test': 1},
        ['X-Test: value'],
      ]) {
        expect(
          () => compile(<String, dynamic>{
            ..._naive,
            'headers': headers,
          }),
          failsAt('naiveproxy.headers'),
          reason: '$headers',
        );
      }
    });

    test('rejects unknown fields at every depth with nearest-name hints', () {
      expect(
        () => compile(<String, dynamic>{
          ..._naive,
          'servre': 'typo.example.com',
        }),
        failsAt('naiveproxy.servre', 'server'),
      );
      expect(
        () => compile(<String, dynamic>{
          ..._naive,
          'connectivity-check': {'timeot': 5},
        }),
        failsAt('naiveproxy.connectivity-check.timeot', 'timeout'),
      );
    });

    test('rejects wrong types and values', () {
      for (final invalid in <String, Object?>{
        'server': 'https://example.com',
        'port': 65536,
        'transport': 'http',
        'insecure-concurrency': 0,
        'tunnel-timeout': double.nan,
        'idle-timeout': 1.5,
        'post-quantum': 'false',
        'host-resolver-rules':
            'MAP example.com 203.0.113.10\nEXCLUDE localhost',
      }.entries) {
        expect(
          () => compile(<String, dynamic>{
            ..._naive,
            invalid.key: invalid.value,
          }),
          failsAt('naiveproxy.${invalid.key}'),
          reason: invalid.key,
        );
      }
    });

    test('rejects fields outside the user contract', () {
      for (final entry in <String, Object?>{
        'proxy': 'https://user:pass@example.com',
        'listen': 'socks://127.0.0.1:1080',
        'log': '/tmp/naiveproxy.log',
        'log-net-log': '/tmp/netlog.json',
        'ssl-key-log-file': '/tmp/keys.log',
        'no-post-quantum': true,
        'resolver-range': '100.64.0.0/10',
        'extra-headers': 'X-Test: value',
      }.entries) {
        expect(
          () => compile(<String, dynamic>{
            ..._naive,
            entry.key: entry.value,
          }),
          failsAt('naiveproxy.${entry.key}', 'forbidden'),
          reason: entry.key,
        );
      }
    });

    test('keeps common connectivity validation strict', () {
      expect(
        () => compile(<String, dynamic>{
          ..._naive,
          'connectivity-check': {'min-success-ratio': 0},
        }),
        failsAt('naiveproxy.connectivity-check.min-success-ratio'),
      );
    });
  });

  group('ByeDPI strict config', () {
    test('accepts maximal manual and auto configs', () {
      expect(
        () => compile(<String, dynamic>{
          'name': 'ByeDPI manual',
          'type': 'byedpi',
          'mode': 'manual',
          'udp': true,
          'args': '--fake=-1 -Qr -s3:5+sm -a1',
        }),
        returnsNormally,
      );
      expect(
        () => compile(<String, dynamic>{
          'name': 'ByeDPI auto',
          'type': 'byedpi',
          'mode': 'auto',
          'udp': false,
          'strategies': [
            '-f-1 -Qr',
            '--split 3:5+sm --udp-fake=1',
          ],
          'strategy-test': {
            'urls': ['https://example.org/generate_204'],
            'sni': 'example.org',
            'resolver': 'https://1.1.1.1/dns-query',
            'timeout': 60,
            'requests': 32,
            'concurrency': 16,
            'min-success-ratio': 1.0,
          },
          'selection': {
            'concurrency': 16,
            'foreground-timeout': 60,
            'background': false,
          },
          'fallback-args': '-s1+s -a1',
          'cache': {
            'ttl': 31536000,
            'recheck-after': 31536000,
            'retry-after': 31536000,
            'failure-threshold': 32,
          },
        }),
        returnsNormally,
      );
    });

    test('rejects mode-incompatible and misspelled nested fields', () {
      expect(
        () => compile(<String, dynamic>{
          'name': 'ByeDPI',
          'type': 'byedpi',
          'mode': 'manual',
          'args': '-f-1',
          'strategy-test': <String, dynamic>{},
        }),
        failsAt('byedpi.strategy-test', 'mode'),
      );
      expect(
        () => compile(<String, dynamic>{
          'name': 'ByeDPI',
          'type': 'byedpi',
          'mode': 'auto',
          'strategy-test': {'concurency': 2},
        }),
        failsAt('byedpi.strategy-test.concurency'),
      );
      expect(
        () => compile(<String, dynamic>{
          'name': 'ByeDPI',
          'type': 'byedpi',
          'mode': 'auto',
          'strategy-test': {'min-success-ratio': 0},
        }),
        failsAt('byedpi.strategy-test.min-success-ratio'),
      );
    });

    test('accepts the `system` resolver but rejects unsafe resolvers', () {
      expect(
        () => compile(<String, dynamic>{
          'name': 'ByeDPI',
          'type': 'byedpi',
          'mode': 'auto',
          'strategies': ['-f-1'],
          'strategy-test': {'resolver': 'system'},
        }),
        returnsNormally,
      );
      for (final resolver in const <String>[
        'http://1.1.1.1/dns-query', // must be https
        'https://127.0.0.1/dns-query', // must be public
        'https://user:pass@1.1.1.1/dns-query', // no credentials
      ]) {
        expect(
          () => compile(<String, dynamic>{
            'name': 'ByeDPI',
            'type': 'byedpi',
            'mode': 'auto',
            'strategies': ['-f-1'],
            'strategy-test': {'resolver': resolver},
          }),
          throwsA(isA<FormatException>()),
          reason: resolver,
        );
      }
    });
  });

  group('OlcRTC strict config', () {
    test('accepts the maximal canonical config', () {
      expect(() => compile(_maximalOlcRtc), returnsNormally);
    });

    test('accepts activation shorthand and complete map forms', () {
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'activation': 'always',
        }),
        returnsNormally,
      );
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'activation': {
            'mode': 'always',
            'wake': {
              'urls': ['https://example.org/generate_204'],
              'interval': 3600,
              'failures': 10,
              'retry-after': 86400,
            },
            'sleep': {'idle': 0},
          },
        }),
        returnsNormally,
      );
    });

    test('rejects unknown nested activation fields and wrong types', () {
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'activation': {
            'wake': {'intervall': 30},
          },
        }),
        failsAt('olcrtc.activation.wake.intervall', 'interval'),
      );
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'activation': true,
        }),
        failsAt('olcrtc.activation', 'string'),
      );
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'activation': 'sometimes',
        }),
        failsAt('olcrtc.activation', 'auto'),
      );
    });

    test('rejects removed profiles, failover and video hardware settings', () {
      for (final entry in <String, Object?>{
        'profiles': <Object>[],
        'failover': <String, Object>{},
      }.entries) {
        expect(
          () => compile(<String, dynamic>{
            ..._minimalOlcRtc,
            entry.key: entry.value,
          }),
          failsAt('olcrtc.${entry.key}'),
        );
      }
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'transport': 'videochannel',
          'transport-options': {'codec': 'qrcode', 'hw': 'none'},
        }),
        failsAt('olcrtc.transport-options.hw'),
      );
    });

    test('reports cross-field transport failures', () {
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'transport': 'datachannel',
          'transport-options': {'fps': 30},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects client-owned and unsupported runtime fields', () {
      for (final invalid in <String, Object?>{
        'mode': 'srv',
        'data': '/tmp/user-data',
        'socks': {'host': '0.0.0.0'},
        'gen': <String, Object>{},
      }.entries) {
        expect(
          () => compile(<String, dynamic>{
            ..._minimalOlcRtc,
            invalid.key: invalid.value,
          }),
          throwsA(isA<FormatException>()),
          reason: invalid.key,
        );
      }
    });
  });

  test('ProfileCompiler validates built-in nodes in the pre-security phase',
      () {
    final rawProfile = RawProfile.fromConfig(
      profile: const Profile(
        id: 'strict-validation-order',
        autoUpdateDuration: Duration.zero,
      ),
      config: const <String, dynamic>{
        'proxies': [
          {
            ..._naive,
            'servre': 'typo.example.com',
          },
        ],
      },
    );

    expect(
      () => const ProfileCompiler().compileProfilePatch(
        rawProfile: rawProfile,
        context: const ProfilePatchContext(
          patchConfig: ClashConfig(),
          overrideNetworkSettings: false,
        ),
      ),
      failsAt('naiveproxy.servre', 'server'),
    );
  });
}

const _key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const _naive = <String, dynamic>{
  'name': 'Naive',
  'type': 'naiveproxy',
  'server': 'example.com',
  'port': 443,
  'username': 'user',
  'password': 'pass',
};

const _minimalOlcRtc = <String, dynamic>{
  'name': 'OlcRTC',
  'type': 'olcrtc',
  'activation': 'always',
  'provider': 'jitsi',
  'room': 'https://meet.example.org/room',
  'encryption-key': _key,
  'transport': 'datachannel',
  'dns-server': '1.1.1.1:53',
};

final _maximalOlcRtc = <String, dynamic>{
  'name': 'OlcRTC',
  'type': 'olcrtc',
  'activation': {
    'mode': 'always',
    'wake': {
      'urls': ['https://example.org/generate_204'],
      'interval': '1h',
      'failures': 10,
      'retry-after': '1d',
    },
    'sleep': {'idle': '0s'},
  },
  'udp': false,
  'provider': 'jitsi',
  'provider-token': 'account-token',
  'room': 'https://meet.example.org/room',
  'room-channel': 'channel-id',
  'encryption-key': _key,
  'transport': 'videochannel',
  'dns-server': '[2606:4700:4700::1111]:53',
  'transport-options': {
    'width': 1080,
    'height': 1080,
    'fps': 30,
    'bitrate': '2M',
    'codec': 'tile',
    'tile-module': 4,
    'tile-rs': 20,
  },
  'liveness': {'interval': '10s', 'timeout': '5s', 'failures': 3},
  'lifecycle': {'max-session-duration': '6h'},
  'traffic': {
    'max-payload-size': 4096,
    'min-delay': '5ms',
    'max-delay': '30ms',
  },
  'debug': false,
  'connectivity-check': {
    'urls': ['https://example.org/generate_204'],
    'required': true,
  },
};
