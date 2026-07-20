import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compiler = BuiltInProxyCompiler();

  BuiltInProxyNodePlan compile(
    Object? activation, {
    List<Map<String, dynamic>>? groups,
    String globalTestUrl = '',
    bool includeActivation = true,
  }) {
    final node = <String, dynamic>{
      ..._olcrtc,
      if (includeActivation) 'activation': activation,
    };
    return compiler
        .compile(
          rawConfig: <String, dynamic>{
            'proxies': [node],
            if (groups != null) 'proxy-groups': groups,
          },
          patchConfig: const ClashConfig(),
          globalTestUrl: globalTestUrl,
        )
        .nodes
        .single;
  }

  test('parses shorthand and defaults omitted activation to auto', () {
    final groups = [
      _group('Reserve', ['RTC'], url: 'https://probe.example/'),
    ];
    final shorthand = compile('auto', groups: groups);
    final omitted = compile(null, groups: groups, includeActivation: false);
    final always = compile('always');

    for (final plan in [shorthand, omitted]) {
      expect(plan.activation!.mode, NodeActivationMode.auto);
      expect(plan.activation!.wakeInterval, const Duration(seconds: 30));
      expect(plan.activation!.wakeFailures, 2);
      expect(plan.activation!.wakeRetryAfter, const Duration(seconds: 300));
      expect(plan.activation!.sleepIdle, const Duration(seconds: 900));
      expect(plan.activation!.wakeUrls.single.host, 'probe.example');
    }
    expect(always.activation!.mode, NodeActivationMode.always);
  });

  test('parses the complete activation map and serializes it', () {
    final plan = compile(
      {
        'mode': 'auto',
        'wake': {
          'urls': ['https://wake.example/generate_204'],
          'interval': 45,
          'failures': 4,
          'retry-after': 600,
        },
        'sleep': {'idle': 0},
      },
      groups: [
        _group('Primary', ['RTC']),
        _group('Fallback', ['RTC']),
      ],
    );

    expect(plan.activation!.toJson(), {
      'mode': 'auto',
      'wake': {
        'urls': ['https://wake.example/generate_204'],
        'interval': 45,
        'failures': 4,
        'retry-after': 600,
      },
      'sleep': {'idle': 0},
      'watch-group': 'Primary',
      'containing-groups': ['Primary', 'Fallback'],
    });
  });

  test('inherits node, nearest group, parent group, and application URLs', () {
    final nodeUrl = compiler
        .compile(
          rawConfig: {
            'proxies': [
              {
                ..._olcrtc,
                'connectivity-check': {
                  'urls': ['https://node.example/'],
                },
              },
            ],
            'proxy-groups': [
              _group('Direct', ['RTC']),
            ],
          },
          patchConfig: const ClashConfig(),
        )
        .nodes
        .single;
    expect(nodeUrl.activation!.wakeUrls.single.host, 'node.example');

    final parentUrl = compile(
      null,
      includeActivation: false,
      groups: [
        _group('Direct', ['RTC']),
        _group('Parent', ['Direct'], url: 'https://parent.example/'),
      ],
    );
    expect(parentUrl.activation!.wakeUrls.single.host, 'parent.example');
    expect(parentUrl.activation!.watchGroup, 'Direct');

    final applicationUrl = compile(
      null,
      includeActivation: false,
      groups: [
        _group('Direct', ['RTC']),
      ],
      globalTestUrl: 'https://application.example/',
    );
    expect(
      applicationUrl.activation!.wakeUrls.single.host,
      'application.example',
    );
  });

  test('rejects unknown activation fields at every level', () {
    for (final activation in [
      {'unexpected': true},
      {
        'wake': {'unexpected': true},
      },
      {
        'sleep': {'unexpected': true},
      },
    ]) {
      expect(
        () => compile(
          activation,
          groups: [
            _group('Reserve', ['RTC'], url: 'https://probe.example/'),
          ],
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('unknown activation'),
          ),
        ),
      );
    }
  });

  test('rejects activation on NaiveProxy and ByeDPI', () {
    for (final node in [
      {
        'name': 'Naive',
        'type': 'naiveproxy',
        'proxy': 'https://user:pass@example.com',
        'activation': 'auto',
      },
      {
        'name': 'ByeDPI',
        'type': 'byedpi',
        'mode': 'manual',
        'args': '--disorder 1',
        'activation': 'auto',
      },
    ]) {
      expect(
        () => compiler.compile(
          rawConfig: {
            'proxies': [node],
          },
          patchConfig: const ClashConfig(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('supported only for olcrtc'),
          ),
        ),
      );
    }
  });

  test('requires a direct group and a resolvable URL in auto mode', () {
    expect(
      () => compile('auto', globalTestUrl: 'https://application.example/'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('direct member'), contains('activation: always')),
        ),
      ),
    );
    expect(
      () => compile(
        'auto',
        groups: [
          _group('Reserve', ['RTC']),
        ],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('no wake address'),
        ),
      ),
    );
  });

  test('enforces activation bounds while allowing sleep.idle zero', () {
    for (final activation in [
      {
        'wake': {'interval': 3601},
      },
      {
        'wake': {'failures': 11},
      },
      {
        'wake': {'retry-after': 86401},
      },
      {
        'sleep': {'idle': -1},
      },
      {
        'sleep': {'idle': 86401},
      },
    ]) {
      expect(
        () => compile(
          activation,
          groups: [
            _group('Reserve', ['RTC'], url: 'https://probe.example/'),
          ],
        ),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      compile(
        {
          'sleep': {'idle': 0},
        },
        groups: [
          _group('Reserve', ['RTC'], url: 'https://probe.example/'),
        ],
      ).activation!.sleepIdle,
      Duration.zero,
    );
  });

  test('always keeps the old proxy and OlcRTC artifact shape', () {
    final result = compiler.compile(
      rawConfig: {
        'proxies': [
          {..._olcrtc, 'activation': 'always'},
        ],
      },
      patchConfig: const ClashConfig(),
    );
    final plan = result.nodes.single;

    expect(result.config['proxies'].single, plan.toProxyConfig());
    expect(plan.files.values.single, isNot(contains('activation')));
    expect(plan.activation!.mode, NodeActivationMode.always);
  });
}

const _olcrtc = <String, dynamic>{
  'name': 'RTC',
  'type': 'olcrtc',
  'auth': {'provider': 'none'},
  'crypto': {
    'key': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  },
  'net': {'transport': 'datachannel', 'dns': '1.1.1.1:53'},
};

Map<String, dynamic> _group(String name, List<String> proxies, {String? url}) =>
    <String, dynamic>{
      'name': name,
      'type': 'fallback',
      'proxies': proxies,
      if (url != null) 'url': url,
    };
