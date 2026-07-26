import 'package:flclashx/product/compile/stormdns_config.dart';
import 'package:flclashx/product/compile/stormdns_config_validator.dart';
import 'package:flutter_test/flutter_test.dart';

const _validator = StormDnsConfigValidator();

Map<String, dynamic> _node([Map<String, dynamic> extra = const {}]) =>
    <String, dynamic>{
      'name': 'Storm',
      'type': 'stormdns',
      'domains': ['v.example.com'],
      'encryption': 'chacha20',
      'encryption-key': 'shared-secret',
      ...extra,
    };

StormDnsSettings _resolve([Map<String, dynamic> extra = const {}]) {
  final node = _node(extra);
  _validator.validateBuiltInNode(node);
  return _validator.validateEffective(
    Map<String, dynamic>.from(node)
      ..remove('name')
      ..remove('type'),
    node: 'stormdns node `Storm`',
  );
}

void _rejects(Map<String, dynamic> extra, {String? because}) {
  expect(
    () => _resolve(extra),
    throwsA(isA<FormatException>()),
    reason: because ?? extra.toString(),
  );
}

void main() {
  group('required server-matched fields', () {
    test('domains, encryption, and encryption-key are all required', () {
      for (final missing in const ['domains', 'encryption', 'encryption-key']) {
        final node = _node()..remove(missing);
        expect(
          () => _validator.validateBuiltInNode(node),
          throwsA(isA<FormatException>()),
          reason: missing,
        );
      }
    });

    test('all six StormDNS encryption methods are accepted', () {
      for (final method in const [
        'none',
        'xor',
        'chacha20',
        'aes-128-gcm',
        'aes-192-gcm',
        'aes-256-gcm',
      ]) {
        expect(_resolve({'encryption': method}).encryption, method,
            reason: method);
      }
    });

    test('an unknown encryption method is rejected', () {
      _rejects({'encryption': 'rc4'});
    });

    test('domains must be real names and are de-duplicated longest first', () {
      expect(
        _resolve({
          'domains': ['b.example.com', 'a.example.com', 'x.io', 'x.io'],
        }).domains,
        ['a.example.com', 'b.example.com', 'x.io'],
      );
      _rejects({
        'domains': ['not a domain'],
      });
      _rejects({'domains': <String>[]});
    });
  });

  group('forbidden fields', () {
    test('app-owned fields are refused with a reason', () {
      for (final field in const [
        'listen',
        'listen-ip',
        'listen-port',
        'port',
        'server',
        'protocol',
        'socks5-auth',
        'socks5-user',
        'socks5-pass',
        'local-dns',
        'local-dns-enabled',
        'local-dns-ip',
        'local-dns-port',
        'local-dns-cache',
        'log-dir',
        'log-file-name',
        'log',
        'resolvers-file',
        'config-version',
      ]) {
        expect(
          () => _validator.validateBuiltInNode(_node({field: 'x'})),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('forbidden'),
            ),
          ),
          reason: field,
        );
      }
    });

    test('an unknown field is refused', () {
      expect(
        () => _validator.validateBuiltInNode(_node({'nope': 1})),
        throwsA(isA<FormatException>()),
      );
    });

    test('startup.mode ask is refused by the schema', () {
      expect(
        () => _validator.validateBuiltInNode(_node({
          'startup': {'mode': 'ask'},
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('startup.mode ask is also refused with an explanation', () {
      // Reached when a caller resolves settings without the schema pass; the
      // message says why the mode can never work on Android.
      expect(
        () => _validator.validateEffective(
          <String, dynamic>{
            'domains': ['v.example.com'],
            'encryption': 'chacha20',
            'encryption-key': 'shared-secret',
            'startup': {'mode': 'ask'},
          },
          node: 'stormdns node `Storm`',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('terminal input'),
          ),
        ),
      );
    });
  });

  group('presets', () {
    test('messenger is the default', () {
      final settings = _resolve();
      expect(settings.uploadDuplication, 1);
      expect(settings.downloadDuplication, 7);
      expect(settings.uploadSetupDuplication, 3);
      expect(settings.downloadSetupDuplication, 8);
      expect(settings.uploadCompression, 'lz4');
      expect(settings.downloadCompression, 'lz4');
    });

    test('balanced and bulk carry their own duplication and compression', () {
      final balanced = _resolve({'preset': 'balanced'});
      expect(
        [
          balanced.uploadDuplication,
          balanced.downloadDuplication,
          balanced.uploadSetupDuplication,
          balanced.downloadSetupDuplication,
        ],
        [2, 5, 3, 6],
      );
      expect(balanced.uploadCompression, 'lz4');

      final bulk = _resolve({'preset': 'bulk'});
      expect(
        [
          bulk.uploadDuplication,
          bulk.downloadDuplication,
          bulk.uploadSetupDuplication,
          bulk.downloadSetupDuplication,
        ],
        [3, 3, 4, 4],
      );
      expect(bulk.uploadCompression, 'zstd');
    });

    test('an explicit field wins over the preset', () {
      final settings = _resolve({
        'preset': 'bulk',
        'duplication': {'upload': 2},
        'compression': {'upload': 'zlib'},
      });
      expect(settings.uploadDuplication, 2, reason: 'explicit beats preset');
      expect(settings.downloadDuplication, 3, reason: 'preset still applies');
      expect(settings.uploadCompression, 'zlib');
      expect(settings.downloadCompression, 'zstd');
    });

    test('an unknown preset is rejected', () {
      _rejects({'preset': 'turbo'});
    });
  });

  group('ranges StormDNS would silently clamp', () {
    test('duplication stays within 1..8', () {
      _rejects({
        'duplication': {'upload': 0},
      });
      _rejects({
        'duplication': {'download': 9},
      });
    });

    test('setup duplication may not sit below its data duplication', () {
      _rejects(
        {
          'duplication': {'upload': 5},
        },
        because: 'preset upload-setup 3 is below the explicit upload 5',
      );
      _rejects({
        'duplication': {'download': 6, 'download-setup': 5},
      });
      expect(
        _resolve({
          'duplication': {'upload': 5, 'upload-setup': 5},
        }).uploadSetupDuplication,
        5,
      );
    });

    test('MTU max may not sit below MTU min', () {
      _rejects({
        'mtu': {
          'upload': {'min': 300, 'max': 200},
        },
      });
      _rejects({
        'mtu': {
          'download': {'min': 4000, 'max': 1000},
        },
      });
      expect(
        _resolve({
          'mtu': {
            'upload': {'min': 120, 'max': 240},
          },
        }).maxUploadMtu,
        240,
      );
    });

    test('an explicit MTU min is checked against the StormDNS default max', () {
      _rejects(
        {
          'mtu': {
            'upload': {'min': 500},
          },
        },
        because: 'the default MAX_UPLOAD_MTU is 200',
      );
    });

    test('arq window and nack gap keep their upstream relationship', () {
      _rejects({
        'arq': {'window': 0},
      });
      _rejects({
        'arq': {'window': 6001},
      });
      _rejects({
        'arq': {'window': 400, 'nack-max-gap': 200},
      });
      expect(
        (_resolve({
          'arq': {'window': 400, 'nack-max-gap': 100},
        }).arq['nack-max-gap']),
        100,
      );
    });

    test('arq RTO ordering is enforced', () {
      _rejects({
        'arq': {'initial-rto': '5s', 'max-rto': '1s'},
      });
      _rejects({
        'arq': {'control-initial-rto': '5s', 'control-max-rto': '1s'},
      });
    });

    test('arq durations outside the clamp window are rejected', () {
      _rejects({
        'arq': {'initial-rto': '10ms'},
      });
      _rejects({
        'arq': {'inactivity-timeout': '10s'},
      });
      _rejects({
        'arq': {'terminal-ack-wait-timeout': '2h'},
      });
    });

    test('ping intervals and thresholds must not invert', () {
      _rejects({
        'ping': {'aggressive-interval': '5s', 'lazy-interval': '1s'},
      });
      _rejects({
        'ping': {'lazy-interval': '10s', 'cooldown-interval': '2s'},
      });
      _rejects({
        'ping': {'cooldown-interval': '30s', 'cold-interval': '10s'},
      });
      _rejects({
        'ping': {'warm-threshold': '30s', 'cool-threshold': '10s'},
      });
      _rejects({
        'ping': {'cool-threshold': '60s', 'cold-threshold': '20s'},
      });
    });

    test('runtime worker counts and session retry bounds are enforced', () {
      _rejects({
        'runtime': {'workers': 0},
      });
      _rejects({
        'runtime': {'workers': 65},
      });
      _rejects({
        'runtime': {'workers': 8, 'process-workers': 4},
      });
      _rejects(
        {
          'runtime': {'workers': 8},
        },
        because: 'the default process worker count is 4',
      );
      _rejects(
        {
          'runtime': {'process-workers': 2},
        },
        because: 'the default RX/TX worker count is 4',
      );
      _rejects({
        'runtime': {'session-retry-base': '30s', 'session-retry-max': '5s'},
      });
      _rejects({
        'runtime': {'tx-channel-size': 32},
      });
      _rejects({
        'runtime': {'idle-poll-interval': '5s'},
      });
    });

    test('compression min-size honours the upstream floor', () {
      _rejects({
        'compression': {'min-size': 50},
      });
      expect(
        _resolve({
          'compression': {'min-size': 200},
        }).compressionMinSize,
        200,
      );
    });

    test('an unknown field inside a block is rejected', () {
      _rejects({
        'arq': {'made-up': 1},
      });
    });
  });

  group('durations', () {
    test('day, hour, and sub-second units all parse', () {
      expect(parseStormDnsDuration('30d'), const Duration(days: 30));
      expect(parseStormDnsDuration('24h'), const Duration(hours: 24));
      expect(parseStormDnsDuration('1m30s'), const Duration(seconds: 90));
      expect(parseStormDnsDuration('500ms'), const Duration(milliseconds: 500));
      expect(parseStormDnsDuration('0.6s'), const Duration(milliseconds: 600));
    });

    test('junk is rejected', () {
      for (final value in const ['', '10', 'abc', '10s junk', '1x2s']) {
        expect(parseStormDnsDuration(value), isNull, reason: value);
      }
    });

    test('startup max-age is an exact integer day count', () {
      expect(
        _resolve({
          'startup': {'max-age': '48h'},
        }).startupMaxAge,
        const Duration(days: 2),
      );
      _rejects({
        'startup': {'max-age': '36h'},
      });
      _rejects({
        'startup': {'max-age': '1.5d'},
      });
    });
  });

  group('resolver policy defaults', () {
    test('defaults match the agreed contract', () {
      final settings = _resolve();
      expect(settings.resolverRefresh, const Duration(hours: 24));
      expect(settings.resolverStrategy, 'least-loss');
      expect(settings.resolverAutoDisable, isTrue);
      expect(settings.resolverRecheck, isTrue);
      expect(settings.startupMode, 'cached');
      expect(settings.startupMaxAge, const Duration(days: 30));
    });

    test('an unknown balancing strategy is rejected', () {
      expect(
        () => _validator.validateBuiltInNode(_node({
          'resolver-policy': {'strategy': 'fastest'},
        })),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
