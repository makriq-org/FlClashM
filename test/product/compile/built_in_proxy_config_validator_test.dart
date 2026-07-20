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
        'proxy': 'https://user:pass@example.com',
        'insecure-concurrency': 4,
        'tunnel-timeout': 3600,
        'idle-timeout': 600,
        'extra-headers': 'X-Test: value',
        'host-resolver-rules': 'MAP example.com 203.0.113.10',
        'resolver-range': '100.64.0.0/10',
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
      expect(config['proxy'], 'https://user:pass@example.com');
      expect(config['insecure-concurrency'], 4);
    });

    test('accepts the pinned list form for alternative proxy chains', () {
      final result = compile(<String, dynamic>{
        'name': 'Naive alternatives',
        'type': 'naiveproxy',
        'proxy': [
          'quic://edge-a.example.com,https://origin.example.com',
          'https://edge-b.example.com',
        ],
      });

      final config = jsonDecode(result.nodes.single.files.values.single) as Map;
      expect(config['proxy'], hasLength(2));
    });

    test('accepts canonical decimal strings supported by the pinned parser',
        () {
      final result = compile(<String, dynamic>{
        ..._naive,
        'insecure-concurrency': '4',
        'tunnel-timeout': '600',
        'idle-timeout': '300',
      });

      final config = jsonDecode(result.nodes.single.files.values.single) as Map;
      expect(config['insecure-concurrency'], '4');
      expect(config['tunnel-timeout'], '600');
      expect(config['idle-timeout'], '300');
    });

    test('reports semantic proxy-chain failures with the list index', () {
      expect(
        () => compile(<String, dynamic>{
          ..._naive,
          'proxy': [
            'https://valid.example.com',
            'https://tcp.example.com,quic://invalid.example.com',
          ],
        }),
        failsAt('naiveproxy.proxy[1]', 'QUIC'),
      );
    });

    test('requires strict CRLF framing for extra headers', () {
      expect(
        () => compile(<String, dynamic>{
          ..._naive,
          'extra-headers': 'X-First: one\r\nX-Second: two',
        }),
        returnsNormally,
      );
      for (final value in [
        'X-First: one\nX-Injected: two',
        'X-First: one\rX-Injected: two',
        'Bad Name: value',
      ]) {
        expect(
          () => compile(<String, dynamic>{
            ..._naive,
            'extra-headers': value,
          }),
          failsAt('naiveproxy.extra-headers'),
          reason: value,
        );
      }
    });

    test('rejects unknown fields at every depth with nearest-name hints', () {
      expect(
        () => compile(<String, dynamic>{
          'name': 'Naive',
          'type': 'naiveproxy',
          'proxxy': 'https://example.com',
        }),
        failsAt('naiveproxy.proxxy', 'proxy'),
      );
      expect(
        () => compile(<String, dynamic>{
          ..._naive,
          'connectivity-check': {'timeot': 5},
        }),
        failsAt('naiveproxy.connectivity-check.timeot', 'timeout'),
      );
    });

    test('rejects wrong types, ranges, and client-owned fields', () {
      for (final invalid in <String, Object?>{
        'proxy': 1,
        'insecure-concurrency': 0,
        'tunnel-timeout': double.nan,
        'idle-timeout': 1.5,
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
      for (final field in ['listen', 'server', 'port']) {
        expect(
          () => compile(<String, dynamic>{
            ..._naive,
            field: field == 'port' ? 1080 : 'value',
          }),
          failsAt('naiveproxy.$field', 'owned'),
          reason: field,
        );
      }
      for (final value in <Object?>[true, false, null, 'yes']) {
        expect(
          () => compile(<String, dynamic>{
            ..._naive,
            'no-post-quantum': value,
          }),
          failsAt('naiveproxy.no-post-quantum', 'cannot be disabled'),
          reason: '$value',
        );
      }
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
        failsAt('byedpi.strategy-test.concurency', 'concurrency'),
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
  });

  group('OlcRTC strict config', () {
    test('accepts maximal recursive base and profile configs', () {
      expect(() => compile(_maximalOlcRtc), returnsNormally);
    });

    test('rejects unknown fields recursively with indexed paths', () {
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'profiles': [
            <String, dynamic>{},
            {
              'crypto': {'kee': _key},
            },
          ],
        }),
        failsAt('olcrtc.profiles[1].crypto.kee', 'key'),
      );
    });

    test('reports indexed paths for profile cross-field failures', () {
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'profiles': [
            {'name': 'first'},
            {
              'name': 'second',
              'traffic': {'min_delay': '2s', 'max_delay': '1s'},
            },
          ],
        }),
        failsAt('olcrtc.profiles[1].traffic.max_delay'),
      );
    });

    test(
        'rejects client-owned and unsupported mode fields in base and profiles',
        () {
      for (final invalid in <String, Object?>{
        'mode': 'srv',
        'data': '/tmp/user-data',
        'socks': {'host': '0.0.0.0'},
        'crypto': {'key': _key, 'key_file': 'secret.key'},
      }.entries) {
        expect(
          () => compile(<String, dynamic>{
            ..._minimalOlcRtc,
            invalid.key: invalid.value,
          }),
          failsAt('olcrtc.${invalid.key}'),
          reason: invalid.key,
        );
      }
      expect(
        () => compile(<String, dynamic>{
          ..._minimalOlcRtc,
          'profiles': [
            {
              'socks': {'port': 9000},
            },
          ],
        }),
        failsAt('olcrtc.profiles[0].socks.port', 'owned'),
      );
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
            'proxxy': 'https://typo.example.com',
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
      failsAt('naiveproxy.proxxy', 'proxy'),
    );
  });
}

const _key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const _naive = <String, dynamic>{
  'name': 'Naive',
  'type': 'naiveproxy',
  'proxy': 'https://user:pass@example.com',
};

const _minimalOlcRtc = <String, dynamic>{
  'name': 'OlcRTC',
  'type': 'olcrtc',
  'mode': 'cnc',
  'auth': {'provider': 'jitsi'},
  'room': {'id': 'https://meet.example.org/room'},
  'crypto': {'key': _key},
  'net': {'transport': 'datachannel', 'dns': '1.1.1.1:53'},
};

final _maximalOlcRtc = <String, dynamic>{
  'name': 'OlcRTC',
  'type': 'olcrtc',
  'mode': 'cnc',
  'udp': false,
  'auth': {'provider': 'jitsi', 'token': 'account-token'},
  'room': {
    'id': 'https://meet.example.org/room',
    'channel': 'channel-id',
  },
  'crypto': {'key': _key},
  'net': {'transport': 'videochannel', 'dns': '[2606:4700:4700::1111]:53'},
  'socks': {
    'user': 'local-user',
    'pass': 'local-pass',
    'proxy_addr': '127.0.0.1',
    'proxy_port': 65535,
    'proxy_user': 'upstream-user',
    'proxy_pass': 'upstream-pass',
  },
  'engine': {
    'name': 'jitsi',
    'url': 'https://meet.example.org',
    'token': 'engine-token',
  },
  'video': {
    'width': 1080,
    'height': 1080,
    'fps': 30,
    'bitrate': '2M',
    'hw': 'none',
    'qr_size': 256,
    'qr_recovery': 'low',
    'codec': 'tile',
    'tile_module': 4,
    'tile_rs': 20,
  },
  'vp8': {'fps': 30, 'batch_size': 64},
  'sei': {
    'fps': 30,
    'batch_size': 64,
    'fragment_size': 900,
    'ack_timeout_ms': 2000,
  },
  'liveness': {'interval': '10s', 'timeout': '5s', 'failures': 3},
  'lifecycle': {'max_session_duration': '6h'},
  'traffic': {
    'max_payload_size': 4096,
    'min_delay': '5ms',
    'max_delay': '30ms',
  },
  'profiles': [
    {
      'name': 'fallback',
      'auth': {'provider': 'wbstream', 'token': 'fallback-token'},
      'room': {'id': 'fallback-room', 'channel': 'fallback-channel'},
      'crypto': {'key': _key},
      'net': {'transport': 'vp8channel', 'dns': '8.8.8.8:53'},
      'socks': {
        'user': 'fallback-user',
        'pass': 'fallback-pass',
        'proxy_addr': '127.0.0.1',
        'proxy_port': 1080,
        'proxy_user': 'proxy-user',
        'proxy_pass': 'proxy-pass',
      },
      'engine': {
        'name': 'jitsi',
        'url': 'https://fallback.example.org',
        'token': 'fallback-engine-token',
      },
      'video': {
        'width': 1920,
        'height': 1080,
        'fps': 30,
        'bitrate': '2M',
        'hw': 'none',
        'qr_size': 256,
        'qr_recovery': 'high',
        'codec': 'qrcode',
        'tile_module': 4,
        'tile_rs': 20,
      },
      'vp8': {'fps': 30, 'batch_size': 64},
      'sei': {
        'fps': 30,
        'batch_size': 64,
        'fragment_size': 900,
        'ack_timeout_ms': 2000,
      },
      'liveness': {'interval': '10s', 'timeout': '5s', 'failures': 3},
      'lifecycle': {'max_session_duration': '6h'},
      'traffic': {
        'max_payload_size': 4096,
        'min_delay': '5ms',
        'max_delay': '30ms',
      },
    },
  ],
  'failover': {'retry_delay': '2s', 'max_cycles': 2},
  'debug': false,
  'connectivity-check': {
    'urls': ['https://example.org/generate_204'],
    'required': true,
  },
};
