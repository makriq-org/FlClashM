import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum ByedpiCliContext { args, strategy, fallbackArgs }

enum ByedpiCliValueKind {
  none,
  text,
  address,
  bufferSize,
  connectionLimit,
  debugLevel,
  positiveInteger,
  nonNegativeInteger,
  uint8,
  timeout,
  autoDetect,
  autoMode,
  inlineData,
  protocolList,
  portRange,
  positiveRange,
  position,
  tlsRecordPosition,
  fakeTlsModifiers,
  escapedCharacter,
  httpModifiers,
}

enum ByedpiCliScope { process, group, groupSeparator }

@immutable
class ByedpiCliOptionSchema {
  const ByedpiCliOptionSchema({
    required this.shortName,
    required this.longName,
    required this.valueKind,
    this.repeatable = false,
    this.contexts = const <ByedpiCliContext>{
      ByedpiCliContext.args,
      ByedpiCliContext.strategy,
      ByedpiCliContext.fallbackArgs,
    },
    this.scope = ByedpiCliScope.group,
    this.forbiddenReason,
  });

  final String shortName;
  final String longName;
  final ByedpiCliValueKind valueKind;
  final bool repeatable;
  final Set<ByedpiCliContext> contexts;
  final ByedpiCliScope scope;
  final String? forbiddenReason;

  bool get takesValue => valueKind != ByedpiCliValueKind.none;
}

@immutable
class ValidatedByedpiCliOption {
  const ValidatedByedpiCliOption({
    required this.name,
    required this.value,
  });

  final String name;
  final String? value;
}

@immutable
class ByedpiCliValidationResult {
  const ByedpiCliValidationResult({
    required this.arguments,
    required this.options,
  });

  final List<String> arguments;
  final List<ValidatedByedpiCliOption> options;
}

const byedpiCliOptions = <ByedpiCliOptionSchema>[
  ByedpiCliOptionSchema(
    shortName: 'N',
    longName: 'no-domain',
    valueKind: ByedpiCliValueKind.none,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'DNS behavior is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'U',
    longName: 'no-udp',
    valueKind: ByedpiCliValueKind.none,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'UDP behavior is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'I',
    longName: 'conn-ip',
    valueKind: ByedpiCliValueKind.address,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'the outbound bind address is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'b',
    longName: 'buf-size',
    valueKind: ByedpiCliValueKind.bufferSize,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'process resource limits are owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'c',
    longName: 'max-conn',
    valueKind: ByedpiCliValueKind.connectionLimit,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'process resource limits are owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'x',
    longName: 'debug',
    valueKind: ByedpiCliValueKind.debugLevel,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'runtime logging is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'F',
    longName: 'tfo',
    valueKind: ByedpiCliValueKind.none,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'process networking is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'T',
    longName: 'timeout',
    valueKind: ByedpiCliValueKind.timeout,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'process timeouts are owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'g',
    longName: 'def-ttl',
    valueKind: ByedpiCliValueKind.uint8,
    scope: ByedpiCliScope.process,
    forbiddenReason: 'process networking is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'A',
    longName: 'auto',
    valueKind: ByedpiCliValueKind.autoDetect,
    repeatable: true,
    scope: ByedpiCliScope.groupSeparator,
  ),
  ByedpiCliOptionSchema(
    shortName: 'L',
    longName: 'auto-mode',
    valueKind: ByedpiCliValueKind.autoMode,
  ),
  ByedpiCliOptionSchema(
    shortName: 'u',
    longName: 'cache-ttl',
    valueKind: ByedpiCliValueKind.positiveInteger,
  ),
  ByedpiCliOptionSchema(
    shortName: 'K',
    longName: 'proto',
    valueKind: ByedpiCliValueKind.protocolList,
  ),
  ByedpiCliOptionSchema(
    shortName: 'H',
    longName: 'hosts',
    valueKind: ByedpiCliValueKind.inlineData,
  ),
  ByedpiCliOptionSchema(
    shortName: 'j',
    longName: 'ipset',
    valueKind: ByedpiCliValueKind.inlineData,
  ),
  ByedpiCliOptionSchema(
    shortName: 'V',
    longName: 'pf',
    valueKind: ByedpiCliValueKind.portRange,
  ),
  ByedpiCliOptionSchema(
    shortName: 'R',
    longName: 'round',
    valueKind: ByedpiCliValueKind.positiveRange,
  ),
  ByedpiCliOptionSchema(
    shortName: 's',
    longName: 'split',
    valueKind: ByedpiCliValueKind.position,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'd',
    longName: 'disorder',
    valueKind: ByedpiCliValueKind.position,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'o',
    longName: 'oob',
    valueKind: ByedpiCliValueKind.position,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'q',
    longName: 'disoob',
    valueKind: ByedpiCliValueKind.position,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'f',
    longName: 'fake',
    valueKind: ByedpiCliValueKind.position,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'S',
    longName: 'md5sig',
    valueKind: ByedpiCliValueKind.none,
  ),
  ByedpiCliOptionSchema(
    shortName: 'n',
    longName: 'fake-sni',
    valueKind: ByedpiCliValueKind.text,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 't',
    longName: 'ttl',
    valueKind: ByedpiCliValueKind.uint8,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'l',
    longName: 'fake-data',
    valueKind: ByedpiCliValueKind.inlineData,
  ),
  ByedpiCliOptionSchema(
    shortName: 'O',
    longName: 'fake-offset',
    valueKind: ByedpiCliValueKind.position,
  ),
  ByedpiCliOptionSchema(
    shortName: 'Q',
    longName: 'fake-tls-mod',
    valueKind: ByedpiCliValueKind.fakeTlsModifiers,
  ),
  ByedpiCliOptionSchema(
    shortName: 'e',
    longName: 'oob-data',
    valueKind: ByedpiCliValueKind.escapedCharacter,
  ),
  ByedpiCliOptionSchema(
    shortName: 'M',
    longName: 'mod-http',
    valueKind: ByedpiCliValueKind.httpModifiers,
  ),
  ByedpiCliOptionSchema(
    shortName: 'r',
    longName: 'tlsrec',
    valueKind: ByedpiCliValueKind.tlsRecordPosition,
    repeatable: true,
  ),
  ByedpiCliOptionSchema(
    shortName: 'm',
    longName: 'tlsminor',
    valueKind: ByedpiCliValueKind.uint8,
  ),
  ByedpiCliOptionSchema(
    shortName: 'a',
    longName: 'udp-fake',
    valueKind: ByedpiCliValueKind.nonNegativeInteger,
  ),
  ByedpiCliOptionSchema(
    shortName: 'Y',
    longName: 'drop-sack',
    valueKind: ByedpiCliValueKind.none,
  ),
  ByedpiCliOptionSchema(
    shortName: 'i',
    longName: 'ip',
    valueKind: ByedpiCliValueKind.address,
    forbiddenReason: 'the listener address is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'p',
    longName: 'port',
    valueKind: ByedpiCliValueKind.positiveInteger,
    forbiddenReason: 'the listener port is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'D',
    longName: 'daemon',
    valueKind: ByedpiCliValueKind.none,
    forbiddenReason: 'process lifecycle is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'w',
    longName: 'pidfile',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'process lifecycle is owned by FlClashM',
  ),
  ByedpiCliOptionSchema(
    shortName: 'E',
    longName: 'transparent',
    valueKind: ByedpiCliValueKind.none,
    forbiddenReason: 'transparent mode bypasses the local SOCKS contract',
  ),
  ByedpiCliOptionSchema(
    shortName: 'P',
    longName: 'protect-path',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'file delivery is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'y',
    longName: 'cache-file',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'user-selected file paths are not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'B',
    longName: 'copy',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'undocumented parser control is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'Z',
    longName: 'wait-send',
    valueKind: ByedpiCliValueKind.none,
    forbiddenReason: 'undocumented runtime control is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'W',
    longName: 'await-int',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'undocumented runtime control is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'C',
    longName: 'connect-to',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'undocumented outbound redirection is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: '#',
    longName: 'comment',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'undocumented parser metadata is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: '/',
    longName: 'cache-merge',
    valueKind: ByedpiCliValueKind.text,
    forbiddenReason: 'undocumented cache control is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'X',
    longName: 'no-ipv6',
    valueKind: ByedpiCliValueKind.none,
    forbiddenReason: 'undocumented network control is not supported',
  ),
  ByedpiCliOptionSchema(
    shortName: 'h',
    longName: 'help',
    valueKind: ByedpiCliValueKind.none,
    forbiddenReason: 'process control flags are not runtime arguments',
  ),
  ByedpiCliOptionSchema(
    shortName: 'v',
    longName: 'version',
    valueKind: ByedpiCliValueKind.none,
    forbiddenReason: 'process control flags are not runtime arguments',
  ),
];

class ByedpiCliValidator {
  const ByedpiCliValidator();

  ByedpiCliValidationResult validate(
    String source, {
    required String path,
    required ByedpiCliContext context,
  }) {
    final arguments = _splitShell(source, path);
    if (arguments.isEmpty) {
      throw FormatException('$path must contain at least one ByeDPI option.');
    }
    final byShort = <String, ByedpiCliOptionSchema>{
      for (final option in byedpiCliOptions) option.shortName: option,
    };
    final byLong = <String, ByedpiCliOptionSchema>{
      for (final option in byedpiCliOptions) option.longName: option,
    };
    final parsed = <ValidatedByedpiCliOption>[];
    final seen = <String, int>{};
    var group = 0;

    void record(ByedpiCliOptionSchema option, String? value) {
      if (option.forbiddenReason case final reason?) {
        throw FormatException(
          '$path: --${option.longName} is forbidden: $reason.',
        );
      }
      if (!option.contexts.contains(context)) {
        throw FormatException(
          '$path: --${option.longName} is not available in ${context.name}.',
        );
      }
      _validateValue(option, value, path);
      final scopeKey =
          option.scope == ByedpiCliScope.process ? 'process' : group;
      final occurrenceKey = '$scopeKey:${option.longName}';
      final count = seen[occurrenceKey] ?? 0;
      if (count > 0 && !option.repeatable) {
        throw FormatException(
          '$path: --${option.longName} must not be repeated in the same context.',
        );
      }
      seen[occurrenceKey] = count + 1;
      parsed.add(
        ValidatedByedpiCliOption(name: option.longName, value: value),
      );
      if (option.scope == ByedpiCliScope.groupSeparator) {
        group++;
      }
    }

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument.startsWith('--')) {
        final separator = argument.indexOf('=');
        final name = separator < 0
            ? argument.substring(2)
            : argument.substring(2, separator);
        final option = byLong[name];
        if (option == null) {
          throw FormatException(
            '$path: unknown ByeDPI option `--$name`${_suggest(name, byLong.keys)}.',
          );
        }
        String? value;
        if (option.takesValue) {
          if (separator >= 0) {
            value = argument.substring(separator + 1);
          } else if (++index < arguments.length) {
            value = arguments[index];
          } else {
            throw FormatException('$path: --$name requires a value.');
          }
        } else if (separator >= 0) {
          throw FormatException('$path: --$name does not accept a value.');
        }
        record(option, value);
        continue;
      }
      if (!argument.startsWith('-') || argument.length == 1) {
        throw FormatException(
          '$path: unexpected positional argument `$argument`.',
        );
      }

      var offset = 1;
      while (offset < argument.length) {
        final name = argument[offset];
        final option = byShort[name];
        if (option == null) {
          throw FormatException('$path: unknown ByeDPI option `-$name`.');
        }
        String? value;
        if (option.takesValue) {
          if (offset + 1 < argument.length) {
            value = argument.substring(offset + 1);
          } else if (++index < arguments.length) {
            value = arguments[index];
          } else {
            throw FormatException('$path: -$name requires a value.');
          }
          offset = argument.length;
        } else {
          offset++;
        }
        record(option, value);
      }
    }

    return ByedpiCliValidationResult(
      arguments: List<String>.unmodifiable(arguments),
      options: List<ValidatedByedpiCliOption>.unmodifiable(parsed),
    );
  }

  void _validateValue(
    ByedpiCliOptionSchema option,
    String? value,
    String path,
  ) {
    if (!option.takesValue) return;
    if (value == null || value.isEmpty) {
      throw FormatException('$path: --${option.longName} requires a value.');
    }
    final valid = switch (option.valueKind) {
      ByedpiCliValueKind.none => true,
      ByedpiCliValueKind.text => _plainText(value),
      ByedpiCliValueKind.address => _address(value),
      ByedpiCliValueKind.bufferSize => _integerRange(value, 1, 536870911),
      ByedpiCliValueKind.connectionLimit => _integerRange(value, 1, 32766),
      ByedpiCliValueKind.debugLevel => _integerRange(value, 0, 2),
      ByedpiCliValueKind.positiveInteger => _integerRange(value, 1, 2147483647),
      ByedpiCliValueKind.nonNegativeInteger =>
        _integerRange(value, 0, 2147483647),
      ByedpiCliValueKind.uint8 => _integerRange(value, 1, 255),
      ByedpiCliValueKind.timeout => RegExp(
          r'^\d+(?:\.\d+)?(?::\d+(?:\.\d+)?(?::\d+(?:\.\d+)?(?::\d+(?:\.\d+)?)?)?)?$',
        ).hasMatch(value),
      ByedpiCliValueKind.autoDetect => _enumList(
          value,
          const <String>{
            't',
            'r',
            's',
            'n',
            'c',
            'torst',
            'redirect',
            'ssl_err',
            'none',
            'conn',
          },
          allowPriority: true),
      ByedpiCliValueKind.autoMode => _enumList(value, const <String>{
          's',
          'o',
          'n',
          'swop',
          'onreconn',
          'noreconn',
        }),
      ByedpiCliValueKind.inlineData =>
        value.startsWith(':') && value.length > 1,
      ByedpiCliValueKind.protocolList => _enumList(value, const <String>{
          't',
          'h',
          'u',
          'i',
          'tls',
          'http',
          'udp',
          'ipv4',
        }),
      ByedpiCliValueKind.portRange => _range(value, 1, 65535),
      ByedpiCliValueKind.positiveRange => _range(value, 1, 2147483647),
      ByedpiCliValueKind.position => _position(value),
      ByedpiCliValueKind.tlsRecordPosition => _tlsRecordPosition(value),
      ByedpiCliValueKind.fakeTlsModifiers => _fakeTlsModifiers(value),
      ByedpiCliValueKind.escapedCharacter => _escapedCharacter(value),
      ByedpiCliValueKind.httpModifiers => _enumList(value, const <String>{
          'h',
          'd',
          'r',
          'hcsmix',
          'dcsmix',
          'rmspace',
        }),
    };
    if (!valid) {
      final detail = option.valueKind == ByedpiCliValueKind.inlineData
          ? ' requires an inline `:value`; file paths are not supported'
          : ' has an invalid value `$value`';
      throw FormatException('$path: --${option.longName}$detail.');
    }
  }

  List<String> _splitShell(String value, String path) {
    final args = <String>[];
    final buffer = StringBuffer();
    var quote = '';
    var escape = false;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (escape) {
        buffer.write(char);
        escape = false;
      } else if (char == r'\') {
        escape = true;
      } else if (quote.isNotEmpty) {
        if (char == quote) {
          quote = '';
        } else {
          buffer.write(char);
        }
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          args.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }
    if (quote.isNotEmpty) {
      throw FormatException('$path contains an unterminated quote.');
    }
    if (escape) {
      throw FormatException('$path ends with an incomplete escape.');
    }
    if (buffer.isNotEmpty) args.add(buffer.toString());
    return args;
  }

  bool _plainText(String value) =>
      value.isNotEmpty &&
      value.codeUnits.every((unit) => unit >= 0x20 && unit != 0x7f);

  bool _address(String value) {
    if (value == 'localhost') return true;
    final uri = Uri.tryParse('socket://$value');
    return uri != null && uri.host.isNotEmpty && !uri.hasPort;
  }

  bool _integerRange(String value, int minimum, int maximum) {
    final parsed = int.tryParse(value);
    return parsed != null && parsed >= minimum && parsed <= maximum;
  }

  bool _range(String value, int minimum, int maximum) {
    final match = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(value);
    if (match == null) return false;
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2) ?? match.group(1)!);
    return start >= minimum && end >= start && end <= maximum;
  }

  bool _position(String value) => RegExp(
        r'^-?(?:0[xX][0-9a-fA-F]+|0[0-7]+|\d+)(?::[1-9]\d*(?::\d+)?)?(?:\+[shn][shemrn]{0,2})?$',
      ).hasMatch(value);

  bool _tlsRecordPosition(String value) {
    if (!_position(value)) return false;
    final suffix = value.indexOf(RegExp(r'[:+]'));
    final rawPosition = suffix < 0 ? value : value.substring(0, suffix);
    final position = _parseBaseZeroInteger(rawPosition);
    return position != null && position <= 0xffff;
  }

  int? _parseBaseZeroInteger(String value) {
    final negative = value.startsWith('-');
    final unsigned = negative ? value.substring(1) : value;
    final radix = unsigned.startsWith(RegExp(r'0[xX]'))
        ? 16
        : unsigned.length > 1 && unsigned.startsWith('0')
            ? 8
            : 10;
    final digits = radix == 16 ? unsigned.substring(2) : unsigned;
    final parsed = int.tryParse(digits, radix: radix);
    return parsed == null
        ? null
        : negative
            ? -parsed
            : parsed;
  }

  bool _enumList(
    String value,
    Set<String> allowed, {
    bool allowPriority = false,
  }) {
    final parts = value.split(',');
    return parts.isNotEmpty &&
        parts.every((part) {
          if (allowed.contains(part)) return true;
          if (allowPriority && part.startsWith('p=')) {
            return double.tryParse(part.substring(2)) != null;
          }
          return false;
        });
  }

  bool _fakeTlsModifiers(String value) => value.split(',').every(
        (part) =>
            const <String>{'r', 'o', 'rand', 'orig'}.contains(part) ||
            RegExp(r'^(?:m|msize)=\d+$').hasMatch(part),
      );

  bool _escapedCharacter(String value) =>
      value.runes.length == 1 ||
      RegExp(r'^\\(?:[rntrfbva\\]|x[0-9a-fA-F]{2}|[0-7]{1,3})$')
          .hasMatch(value);

  String _suggest(String value, Iterable<String> candidates) {
    if (candidates.isEmpty) return '';
    final nearest = candidates.reduce(
      (best, candidate) => _distance(value, candidate) < _distance(value, best)
          ? candidate
          : best,
    );
    return '; did you mean `--$nearest`?';
  }

  int _distance(String left, String right) {
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var i = 0; i < left.length; i++) {
      final current = <int>[i + 1];
      for (var j = 0; j < right.length; j++) {
        current.add(
          math.min(
            math.min(current[j] + 1, previous[j + 1] + 1),
            previous[j] + (left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    return previous.last;
  }
}
