import 'package:flclashx/product/compile/built_in_proxy_schema.dart';
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

/// Resolves the way the apply path does: `validate: false`, so
/// [StormDnsConfigValidator.validateBuiltInNode] never runs.
StormDnsSettings _resolveWithoutSchema([
  Map<String, dynamic> extra = const {},
]) {
  final node = _node(extra)
    ..remove('name')
    ..remove('type');
  return const StormDnsSettingsResolver()
      .resolve(node, node: 'stormdns node `Storm`');
}

void _rejectsWithoutSchema(Map<String, dynamic> extra, {String? because}) {
  expect(
    () => _resolveWithoutSchema(extra),
    throwsA(isA<FormatException>()),
    reason: because ?? extra.toString(),
  );
}

/// Asserts the resolver alone refuses [value] for [path].
void _rejectsRange(String path, int value) {
  final segments = path.split('.');
  var nested = <String, dynamic>{segments.last: value};
  for (final segment in segments.reversed.skip(1)) {
    nested = <String, dynamic>{segment: nested};
  }
  expect(
    () => _resolveWithoutSchema(nested),
    throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        allOf(contains(path), contains('clamp')),
      ),
    ),
    reason: '$path = $value',
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

  group('numeric ranges never reach the generated TOML', () {
    // Same hole as the enum group below: the apply path compiles with
    // `validate: false`, so the schema pass that owns these bounds is skipped
    // and only the resolver stands between a profile and the TOML writer.
    test('every schema range is enforced without the schema pass', () {
      expect(stormDnsIntegerRanges, isNotEmpty);
      for (final entry in stormDnsIntegerRanges.entries) {
        final path = entry.key;
        final minimum = entry.value.minimum;
        final maximum = entry.value.maximum;
        expect(
          minimum != null || maximum != null,
          isTrue,
          reason: '$path is listed without bounds',
        );
        if (minimum != null) {
          _rejectsRange(path, minimum.toInt() - 1);
        }
        if (maximum != null) {
          _rejectsRange(path, maximum.toInt() + 1);
        }
      }
    });

    test('an out-of-range value is refused instead of being clamped', () {
      _rejectsWithoutSchema({
        'duplication': {'upload': 99, 'upload-setup': 99},
      });
      _rejectsWithoutSchema({
        'arq': {'window': -5},
      });
    });
  });

  group('an empty value is not an absent one', () {
    test('an empty duration is reported instead of crashing', () {
      _rejectsWithoutSchema({
        'arq': {'initial-rto': null},
      });
      _rejectsWithoutSchema({
        'resolver-policy': {'refresh': null},
      });
      _rejectsWithoutSchema({
        'startup': {'max-age': null},
      });
    });

    test('an empty integer does not become zero', () {
      _rejectsWithoutSchema({
        'arq': {'window': null},
      });
      _rejectsWithoutSchema({
        'duplication': {'upload': null},
      });
      _rejectsWithoutSchema({
        'mtu': {
          'upload': {'min': null},
        },
      });
    });

    test('an empty enum or boolean does not fall back to a default', () {
      _rejectsWithoutSchema({
        'compression': {'upload': null},
      });
      _rejectsWithoutSchema({
        'resolver-policy': {'auto-disable': null},
      });
      _rejectsWithoutSchema({'preset': null});
      _rejectsWithoutSchema({
        'startup': {'mode': null},
      });
    });

    test('an absent key still takes its preset or documented default', () {
      final settings = _resolveWithoutSchema({
        'duplication': <String, dynamic>{},
        'compression': <String, dynamic>{},
        'resolver-policy': <String, dynamic>{},
        'startup': <String, dynamic>{},
        'mtu': {'upload': <String, dynamic>{}},
      });
      // The `messenger` preset, untouched by the empty blocks.
      expect(settings.uploadDuplication, 1);
      expect(settings.uploadCompression, 'lz4');
      expect(settings.resolverAutoDisable, isTrue);
      expect(settings.startupMode, 'cached');
      expect(settings.startupMaxAge, const Duration(days: 30));
      expect(settings.minUploadMtu, isNull);
    });
  });

  group('a value of the wrong type is not a default', () {
    test('a non-boolean is refused instead of being read as the default', () {
      // `"yes"` is a string, and taking the default for it ran the node with
      // the opposite of what the profile says.
      for (final value in const <Object>['yes', 'true', 1, 0]) {
        _rejectsWithoutSchema(
          {
            'resolver-policy': {'auto-disable': value},
          },
          because: '$value',
        );
        _rejectsWithoutSchema(
          {
            'resolver-policy': {'recheck': value},
          },
          because: '$value',
        );
        _rejectsWithoutSchema(
          {
            'runtime': {'base-encode': value},
          },
          because: '$value',
        );
      }
    });

    test('every boolean field reports the same way', () {
      for (final extra in const <Map<String, dynamic>>[
        {
          'resolver-policy': {'auto-disable': 'yes'},
        },
        {
          'runtime': {'base-encode': 'yes'},
        },
      ]) {
        expect(
          () => _resolveWithoutSchema(extra),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('must be a boolean'),
            ),
          ),
          reason: extra.toString(),
        );
      }
    });

    test('a non-string enum value is refused, not replaced by the default', () {
      _rejectsWithoutSchema({'preset': 42});
      _rejectsWithoutSchema({'preset': ''});
      _rejectsWithoutSchema({
        'startup': {'mode': 5},
      });
      _rejectsWithoutSchema({
        'compression': {'upload': 5},
      });
      _rejectsWithoutSchema({
        'compression': {'download': '  '},
      });
      _rejectsWithoutSchema({
        'resolver-policy': {'strategy': <String>[]},
      });
    });

    test('the rejection still names the values that are allowed', () {
      expect(
        () => _resolveWithoutSchema({
          'compression': {'upload': 5},
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('compression.upload'), contains('zstd')),
          ),
        ),
      );
    });

    test('a boolean and an enum still take their default when absent', () {
      final settings = _resolveWithoutSchema();
      expect(settings.resolverAutoDisable, isTrue);
      expect(settings.resolverRecheck, isTrue);
      expect(settings.startupMode, 'cached');
      expect(settings.uploadCompression, 'lz4');
      expect(settings.runtime['base-encode'], isNull);
    });
  });

  group('unknown enum values never reach the generated TOML', () {
    // The apply path compiles with `validate: false`, so the schema pass that
    // knows these value sets is skipped and only the resolver stands between a
    // profile and the TOML writer.
    test('the resolver rejects them without the schema pass', () {
      _rejects({
        'resolver-policy': {'strategy': 'fastest'},
      });
      _rejects({
        'compression': {'upload': 'brotli'},
      });
      _rejects({
        'compression': {'download': 'brotli'},
      });
    });

    test('the rejection names the values that are allowed', () {
      expect(
        () => _resolve({
          'compression': {'upload': 'brotli'},
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('compression.upload'), contains('zstd')),
          ),
        ),
      );
    });

    test('every documented value still resolves', () {
      for (final type in const ['none', 'zstd', 'lz4', 'zlib']) {
        expect(_resolve({'compression': {'upload': type}}).uploadCompression,
            type,
            reason: type);
        expect(
            _resolve({'compression': {'download': type}}).downloadCompression,
            type,
            reason: type);
      }
      for (final strategy in const [
        'random',
        'round-robin',
        'least-loss',
        'lowest-latency',
      ]) {
        expect(
          _resolve({
            'resolver-policy': {'strategy': strategy},
          }).resolverStrategy,
          strategy,
          reason: strategy,
        );
      }
    });

    test('the TOML writer refuses an unmapped value instead of writing null',
        () {
      final settings = _resolve();
      for (final broken in <StormDnsSettings>[
        _copyWith(settings, resolverStrategy: 'fastest'),
        _copyWith(settings, uploadCompression: 'brotli'),
        _copyWith(settings, downloadCompression: 'brotli'),
        _copyWith(settings, encryption: 'rot13'),
        _copyWith(settings, startupMode: 'ask'),
      ]) {
        expect(
          () => buildStormDnsToml(
            settings: broken,
            listenHost: '127.0.0.1',
            listenPort: 7890,
            logDirectory: 'logs',
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('a valid settings object writes no null anywhere', () {
      final toml = buildStormDnsToml(
        settings: _resolve(),
        listenHost: '127.0.0.1',
        listenPort: 7890,
        logDirectory: 'logs',
      );
      expect(toml, isNot(contains('null')));
      // `least-loss` and the `messenger` preset's `lz4`, as StormDNS codes.
      expect(toml, contains('RESOLVER_BALANCING_STRATEGY = 3'));
      expect(toml, contains('UPLOAD_COMPRESSION_TYPE = 2'));
      expect(toml, contains('DOWNLOAD_COMPRESSION_TYPE = 2'));
    });
  });
}

/// Rebuilds [settings] with one field replaced, so the TOML writer can be
/// handed a value that validation would never have produced.
StormDnsSettings _copyWith(
  StormDnsSettings settings, {
  String? resolverStrategy,
  String? uploadCompression,
  String? downloadCompression,
  String? encryption,
  String? startupMode,
}) =>
    StormDnsSettings(
      domains: settings.domains,
      encryption: encryption ?? settings.encryption,
      encryptionKey: settings.encryptionKey,
      uploadDuplication: settings.uploadDuplication,
      downloadDuplication: settings.downloadDuplication,
      uploadSetupDuplication: settings.uploadSetupDuplication,
      downloadSetupDuplication: settings.downloadSetupDuplication,
      uploadCompression: uploadCompression ?? settings.uploadCompression,
      downloadCompression: downloadCompression ?? settings.downloadCompression,
      compressionMinSize: settings.compressionMinSize,
      minUploadMtu: settings.minUploadMtu,
      maxUploadMtu: settings.maxUploadMtu,
      minDownloadMtu: settings.minDownloadMtu,
      maxDownloadMtu: settings.maxDownloadMtu,
      resolverStrategy: resolverStrategy ?? settings.resolverStrategy,
      resolverRefresh: settings.resolverRefresh,
      resolverAutoDisable: settings.resolverAutoDisable,
      resolverRecheck: settings.resolverRecheck,
      startupMode: startupMode ?? settings.startupMode,
      startupMaxAge: settings.startupMaxAge,
      arq: settings.arq,
      ping: settings.ping,
      runtime: settings.runtime,
    );
