import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flclashx/product/compile/stormdns_resolver_sources.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/stormdns_release.dart';
import 'package:flutter_test/flutter_test.dart';

const _compiler = BuiltInProxyCompiler();

CompiledBuiltInProxyNodes _compile(
  Map<String, dynamic> node, {
  Map<Uri, StormDnsRemoteResolverList> remoteLists = const {},
  List<Map<String, dynamic>>? groups,
}) =>
    _compiler.compile(
      rawConfig: <String, dynamic>{
        'proxies': [node],
        'proxy-groups': groups ??
            [
              {
                'name': 'Reserve',
                'proxies': [node['name'], 'DIRECT'],
                'url': 'https://example.com/generate_204',
              },
            ],
      },
      patchConfig: const ClashConfig(),
      stormDnsRemoteLists: remoteLists,
    );

Map<String, dynamic> _node([Map<String, dynamic> extra = const {}]) =>
    <String, dynamic>{
      'name': 'Storm',
      'type': 'stormdns',
      'domains': ['v.example.com'],
      'encryption': 'chacha20',
      'encryption-key': 'shared-secret',
      ...extra,
    };

String _toml(BuiltInProxyNodePlan plan) => plan
    .files['built-in-proxies/stormdns/${plan.nodeId}/$stormDnsConfigFileName']!;

String _resolvers(BuiltInProxyNodePlan plan) => plan.files[
    'built-in-proxies/stormdns/${plan.nodeId}/'
    '$stormDnsResolversTemplateFileName']!;

void main() {
  group('generated TOML', () {
    test('carries the server-matched values and app-owned listener', () {
      final plan = _compile(_node()).nodes.single;
      final toml = _toml(plan);

      expect(toml, contains('PROTOCOL_TYPE = "SOCKS5"'));
      expect(toml, contains('LISTEN_IP = "127.0.0.1"'));
      expect(toml, contains('LISTEN_PORT = ${plan.listenPort}'));
      expect(toml, contains('SOCKS5_AUTH = false'));
      expect(toml, contains('LOCAL_DNS_ENABLED = false'));
      expect(toml, contains('DOMAINS = ["v.example.com"]'));
      expect(toml, contains('DATA_ENCRYPTION_METHOD = 2'));
      expect(toml, contains('ENCRYPTION_KEY = "shared-secret"'));
      expect(plan.listenPort, inInclusiveRange(36200, 36455));
    });

    test('the resolver cache log is forced on with an app-owned directory', () {
      final plan = _compile(_node()).nodes.single;
      final toml = _toml(plan);
      final fingerprint = plan.metadata['cache-fingerprint']!;

      expect(toml, contains('LOG_TO_FILE = true'));
      expect(toml, contains('LOG_DIR = "cache/$fingerprint/logs"'));
    });

    test('preset duplication and compression reach the TOML', () {
      final toml = _toml(_compile(_node({'preset': 'bulk'})).nodes.single);
      expect(toml, contains('UPLOAD_PACKET_DUPLICATION_COUNT = 3'));
      expect(toml, contains('DOWNLOAD_PACKET_DUPLICATION_COUNT = 3'));
      expect(toml, contains('UPLOAD_SETUP_PACKET_DUPLICATION_COUNT = 4'));
      expect(toml, contains('DOWNLOAD_SETUP_PACKET_DUPLICATION_COUNT = 4'));
      expect(toml, contains('UPLOAD_COMPRESSION_TYPE = 1'));
    });

    test('startup modes translate to STARTUP_MODE and MTU verification', () {
      String tomlFor(String mode) => _toml(_compile(_node({
            'startup': {'mode': mode},
          })).nodes.single);

      expect(tomlFor('scan'), contains('STARTUP_MODE = "resolvers"'));
      expect(tomlFor('scan'), contains('LOG_BASED_MTU_VERIFY = false'));
      expect(tomlFor('cached'), contains('STARTUP_MODE = "logs"'));
      expect(tomlFor('cached'), contains('LOG_BASED_MTU_VERIFY = false'));
      expect(tomlFor('verified'), contains('STARTUP_MODE = "logs"'));
      expect(tomlFor('verified'), contains('LOG_BASED_MTU_VERIFY = true'));
    });

    test('startup max-age is emitted in days', () {
      final toml = _toml(_compile(_node({
        'startup': {'max-age': '7d'},
      })).nodes.single);
      expect(toml, contains('LOG_SCAN_MAX_DAYS = 7'));
    });

    test('durations are emitted as float seconds', () {
      final toml = _toml(_compile(_node({
        'arq': {'initial-rto': '600ms', 'max-rto': '3s'},
        'ping': {'watchdog-timeout': '5m'},
      })).nodes.single);
      expect(toml, contains('ARQ_INITIAL_RTO_SECONDS = 0.6'));
      expect(toml, contains('ARQ_MAX_RTO_SECONDS = 3.0'));
      expect(toml, contains('PING_WATCHDOG_TIMEOUT_SECONDS = 300.0'));
    });

    test('resolver policy booleans and strategy reach the TOML', () {
      final toml = _toml(_compile(_node({
        'resolver-policy': {
          'strategy': 'lowest-latency',
          'auto-disable': false,
          'recheck': false,
        },
      })).nodes.single);
      expect(toml, contains('RESOLVER_BALANCING_STRATEGY = 4'));
      expect(toml, contains('AUTO_DISABLE_TIMEOUT_SERVERS = false'));
      expect(toml, contains('RECHECK_INACTIVE_SERVERS_ENABLED = false'));
    });
  });

  group('generated resolver template', () {
    test('defaults to the system placeholder', () {
      final plan = _compile(_node()).nodes.single;
      expect(_resolvers(plan).trim(), stormDnsSystemDnsPlaceholder);
      expect(plan.metadata['depends-on-system-dns'], 'true');
    });

    test('expands every source type in declaration order', () {
      final url = Uri.parse('https://example.com/r.txt');
      final plan = _compile(
        _node({
          'resolvers': [
            'system',
            '8.8.8.8',
            '1.1.1.1:5353',
            '192.168.1.0/30',
            url.toString(),
          ],
        }),
        remoteLists: {
          url: StormDnsRemoteResolverList(
            entries: const [StormDnsResolverEntry(ip: '9.9.9.9', port: 53)],
            fetchedAt: DateTime(2026),
          ),
        },
      ).nodes.single;

      expect(_resolvers(plan).trim().split('\n'), [
        stormDnsSystemDnsPlaceholder,
        '8.8.8.8',
        '1.1.1.1:5353',
        '192.168.1.1',
        '192.168.1.2',
        '9.9.9.9',
      ]);
    });

    test('a list without system does not depend on system DNS', () {
      final plan = _compile(_node({
        'resolvers': ['8.8.8.8'],
      })).nodes.single;
      expect(plan.metadata['depends-on-system-dns'], 'false');
      expect(_resolvers(plan).trim(), '8.8.8.8');
    });

    test('a profile whose sources all resolve to nothing is rejected', () {
      expect(
        () => _compile(_node({
          'resolvers': ['https://example.com/missing.txt'],
        })),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('working cache fingerprint', () {
    test('is stable for the same resolvers and domains', () {
      final first = _compile(_node()).nodes.single;
      final second = _compile(_node()).nodes.single;
      expect(
        first.metadata['cache-fingerprint'],
        second.metadata['cache-fingerprint'],
      );
    });

    test('changes when the resolver list changes', () {
      final base = _compile(_node()).nodes.single;
      final changed = _compile(_node({
        'resolvers': ['system', '8.8.8.8'],
      })).nodes.single;
      expect(
        changed.metadata['cache-fingerprint'],
        isNot(base.metadata['cache-fingerprint']),
      );
    });

    test('changes when domains change', () {
      final base = _compile(_node()).nodes.single;
      final changed = _compile(_node({
        'domains': ['w.example.com'],
      })).nodes.single;
      expect(
        changed.metadata['cache-fingerprint'],
        isNot(base.metadata['cache-fingerprint']),
      );
    });

    test('does not change when an unrelated tuning field changes', () {
      final base = _compile(_node()).nodes.single;
      final tuned = _compile(_node({'preset': 'bulk'})).nodes.single;
      expect(
        tuned.metadata['cache-fingerprint'],
        base.metadata['cache-fingerprint'],
        reason: 'tuning does not invalidate a measured resolver cache',
      );
    });
  });

  group('activation', () {
    test('defaults to auto so a reserve node sleeps', () {
      final plan = _compile(_node()).nodes.single;
      expect(plan.activation!.mode, NodeActivationMode.auto);
      expect(plan.activation!.isAuto, isTrue);
      expect(plan.activation!.containingGroups, ['Reserve']);
    });

    test('always keeps the node running', () {
      final plan = _compile(_node({'activation': 'always'})).nodes.single;
      expect(plan.activation!.mode, NodeActivationMode.always);
    });

    test('auto activation needs a containing group', () {
      expect(
        () => _compile(_node(), groups: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('connectivity-check keeps whole-second values', () {
      final plan = _compile(_node({
        'connectivity-check': {'timeout': 25, 'startup-timeout': 180},
      })).nodes.single;
      expect(plan.connectivityCheck.timeout, const Duration(seconds: 25));
      expect(
        plan.connectivityCheck.startupTimeout,
        const Duration(seconds: 180),
      );
    });
  });

  test('the node is rewritten as a plain SOCKS5 proxy entry', () {
    final compiled = _compile(_node());
    final proxy = (compiled.config['proxies'] as List).single as Map;
    expect(proxy['type'], 'socks5');
    expect(proxy['server'], '127.0.0.1');
    expect(proxy['udp'], isFalse);
  });

  test('remote list addresses are collected with their refresh window', () {
    final requested = _compiler.collectStormDnsRemoteLists(<String, dynamic>{
      'proxies': [
        _node({
          'resolvers': ['https://example.com/r.txt'],
          'resolver-policy': {'refresh': '6h'},
        }),
      ],
    });
    expect(requested, {Uri.parse('https://example.com/r.txt'): const Duration(hours: 6)});
  });
}
