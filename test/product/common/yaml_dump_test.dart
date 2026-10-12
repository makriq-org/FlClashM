import 'package:flclashx/common/yaml_dump.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

dynamic _materialize(dynamic value) {
  if (value is YamlMap) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _materialize(entry.value),
    };
  }
  if (value is YamlList) {
    return value.map(_materialize).toList();
  }
  return value;
}

String _encode(dynamic value) {
  final buffer = StringBuffer();
  yamlDump(buffer, value, 0);
  return buffer.toString();
}

void main() {
  group('yamlDump', () {
    test('preserves strings that YAML can mistake for syntax or scalars', () {
      const strings = <String>[
        '*',
        '&anchor',
        '!tag',
        '- item',
        '? key',
        ': value',
        '# comment',
        '{flow: map}',
        '[flow, list]',
        'true',
        'false',
        'null',
        '~',
        'yes',
        'no',
        'on',
        'off',
        '123',
        '01',
        '1e3',
        '2026-08-15',
        ' leading',
        'trailing ',
        'quote"slash\\tab\tnewline\n',
        '',
      ];
      final source = <String, dynamic>{
        'expected-status': '*',
        'values': strings,
      };

      expect(_materialize(loadYaml(_encode(source))), source);
    });

    test('preserves empty and nested collections', () {
      final source = <String, dynamic>{
        'empty-map': <String, dynamic>{},
        'empty-list': <dynamic>[],
        'nested': <dynamic>[
          <String, dynamic>{},
          <dynamic>[],
          <String, dynamic>{
            'list': <dynamic>[
              <String, dynamic>{'value': '*'},
            ],
          },
        ],
      };

      expect(_materialize(loadYaml(_encode(source))), source);
    });

    test('quotes ambiguous and complex map keys', () {
      const source = <String, dynamic>{
        'true': 'boolean-looking key',
        '123': 'numeric-looking key',
        'key: value': 'mapping-looking key',
        '*': 'alias-looking key',
      };

      expect(_materialize(loadYaml(_encode(source))), source);
    });
  });
}
