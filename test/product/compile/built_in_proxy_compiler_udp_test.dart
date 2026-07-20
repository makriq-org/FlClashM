import 'dart:convert';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/built_in_proxy_compiler.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compiler = BuiltInProxyCompiler();

  group('BuiltInProxyCompiler UDP', () {
    test('uses the UDP default of every built-in node type', () {
      for (final entry in <BuiltInProxyType, bool>{
        BuiltInProxyType.byedpi: true,
        BuiltInProxyType.naiveproxy: false,
        BuiltInProxyType.olcrtc: false,
      }.entries) {
        final compiled = _compile(compiler, _validNode(entry.key));

        expect(compiled.nodes.single.udp, entry.value);
        expect(compiled.config['proxies'][0]['udp'], entry.value);
      }
    });

    test('allows explicit udp true for ByeDPI', () {
      final node = _validNode(BuiltInProxyType.byedpi)..['udp'] = true;
      final compiled = _compile(compiler, node);
      final plan = compiled.nodes.single;

      expect(plan.udp, isTrue);
      expect(compiled.config['proxies'][0]['udp'], isTrue);
      final config = json.decode(plan.files.values.single) as Map;
      expect(config, isNot(contains('udp')));
    });

    test('allows explicit udp false for every built-in node type', () {
      for (final type in BuiltInProxyType.values) {
        final node = _validNode(type)..['udp'] = false;
        final compiled = _compile(compiler, node);

        expect(compiled.nodes.single.udp, isFalse);
        expect(compiled.config['proxies'][0]['udp'], isFalse);
      }
    });

    test('rejects udp true for node types without UDP support', () {
      for (final type in [
        BuiltInProxyType.naiveproxy,
        BuiltInProxyType.olcrtc,
      ]) {
        final node = _validNode(type)..['udp'] = true;

        expect(
          () => _compile(compiler, node),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              '${type.label} built-in nodes do not support `udp: true`.',
            ),
          ),
        );
      }
    });

    test('rejects non-boolean UDP values for every built-in node type', () {
      for (final type in BuiltInProxyType.values) {
        for (final value in <Object?>[
          null,
          1,
          'true',
          const <String, bool>{},
        ]) {
          final node = _validNode(type)..['udp'] = value;

          expect(
            () => _compile(compiler, node),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                contains('${type.label}.udp must be a boolean'),
              ),
            ),
          );
        }
      }
    });
  });
}

CompiledBuiltInProxyNodes _compile(
  BuiltInProxyCompiler compiler,
  Map<String, dynamic> node,
) => compiler.compile(
  rawConfig: <String, dynamic>{
    'proxies': [node],
  },
  patchConfig: const ClashConfig(),
);

Map<String, dynamic> _validNode(BuiltInProxyType type) => switch (type) {
  BuiltInProxyType.byedpi => <String, dynamic>{
    'name': 'ByeDPI Local',
    'type': 'byedpi',
    'mode': 'manual',
    'args': '--disorder 1 --auto=torst --tlsrec 1+s',
  },
  BuiltInProxyType.naiveproxy => <String, dynamic>{
    'name': 'NaiveProxy Local',
    'type': 'naiveproxy',
    'server': 'example.com',
    'port': 443,
    'username': 'user',
    'password': 'pass',
  },
  BuiltInProxyType.olcrtc => <String, dynamic>{
    'name': 'OlcRTC Local',
    'type': 'olcrtc',
    'auth': {'provider': 'none'},
    'crypto': {
      'key': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    },
    'net': {'transport': 'datachannel', 'dns': '1.1.1.1:53'},
  },
};
