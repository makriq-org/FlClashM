import '../runtime/built_in_proxy_types.dart';

/// Converts accepted legacy spellings to the public canonical node contract.
/// Runtime compilers only ever receive the returned map.
class BuiltInProxyNormalizer {
  const BuiltInProxyNormalizer();

  Map<String, dynamic> normalize(Map<dynamic, dynamic> input) {
    final node = _normalizeKeys(input, path: 'proxy');
    final type = BuiltInProxyTypeLabel.tryParse(_string(node['type']));
    if (type == null) return node;
    return switch (type) {
      BuiltInProxyType.naiveproxy => node,
      BuiltInProxyType.stormdns => node,
      BuiltInProxyType.byedpi => _normalizeByedpi(node),
      BuiltInProxyType.olcrtc => _normalizeOlcRtc(node),
    };
  }

  Map<String, dynamic> _normalizeByedpi(Map<String, dynamic> node) {
    _move(node, 'args', 'strategy', path: 'byedpi');
    final mode = node.containsKey('mode')
        ? _string(node['mode'])
        : (node.containsKey('strategy') ? 'manual' : 'auto');
    if (!node.containsKey('mode')) node['mode'] = mode;
    if (mode != 'auto') return node;

    if (node.containsKey('strategy-list')) {
      if (node.containsKey('strategies')) {
        throw const FormatException(
          'byedpi `strategy-list` conflicts with canonical `strategies`.',
        );
      }
      final value = _string(node.remove('strategy-list'));
      if (value == null) {
        throw const FormatException(
          'byedpi `strategy-list` must be a non-empty string.',
        );
      }
      node['strategies'] = <String>['builtin:$value'];
    }

    final test = _map(node['strategy-test']);
    if (test != null) {
      _move(test, 'resolver', 'dns-resolver', path: 'strategy-test');
      _move(test, 'concurrency', 'request-concurrency', path: 'strategy-test');
      node['strategy-test'] = test;
    }

    final legacySelection = _map(node.remove('selection'));
    final selection = _map(node['strategy-selection']) ?? <String, dynamic>{};
    if (legacySelection != null) {
      if (node.containsKey('strategy-selection')) {
        throw const FormatException(
          'byedpi `selection` conflicts with canonical `strategy-selection`.',
        );
      }
      _move(
        legacySelection,
        'concurrency',
        'strategy-concurrency',
        path: 'selection',
      );
      _move(
        legacySelection,
        'foreground-timeout',
        'startup-timeout',
        path: 'selection',
      );
      _move(
        legacySelection,
        'background',
        'continue-in-background',
        path: 'selection',
      );
      selection.addAll(legacySelection);
    }
    if (node.containsKey('fallback-args')) {
      _move(node, 'fallback-args', '_legacy-fallback-strategy', path: 'byedpi');
      if (selection.containsKey('fallback-strategy')) {
        throw const FormatException(
          'byedpi `fallback-args` conflicts with '
          '`strategy-selection.fallback-strategy`.',
        );
      }
      selection['fallback-strategy'] = node.remove('_legacy-fallback-strategy');
    }
    final legacyCache = _map(node.remove('cache'));
    if (legacyCache != null) {
      if (selection.containsKey('cache')) {
        throw const FormatException(
          'byedpi legacy `cache` conflicts with '
          '`strategy-selection.cache`.',
        );
      }
      if (legacyCache.containsKey('retry-after')) {
        if (selection.containsKey('retry-after')) {
          throw const FormatException(
            'byedpi `cache.retry-after` conflicts with '
            '`strategy-selection.retry-after`.',
          );
        }
        selection['retry-after'] = legacyCache.remove('retry-after');
      }
      selection['cache'] = legacyCache;
    }
    if (selection.isNotEmpty ||
        legacySelection != null ||
        node.containsKey('strategy-selection')) {
      node['strategy-selection'] = selection;
    }
    return node;
  }

  Map<String, dynamic> _normalizeOlcRtc(Map<String, dynamic> node) {
    if (node.containsKey('mode')) {
      if (_string(node['mode']) != 'cnc') {
        throw const FormatException(
          'olcrtc.mode supports only legacy value `cnc`.',
        );
      }
      node.remove('mode');
    }
    void flatten(String section, Map<String, String> aliases) {
      final value = node[section];
      if (value == null) return;
      final map = _map(value);
      if (map == null) {
        // `room` and `engine` are canonical scalar fields too.
        if (section == 'room' || section == 'engine') return;
        throw FormatException('olcrtc legacy `$section` must be a map.');
      }
      node.remove(section);
      for (final entry in map.entries) {
        final target = aliases[entry.key];
        if (target == null) {
          throw FormatException(
            'olcrtc `$section.${entry.key}` is no longer supported.',
          );
        }
        if (node.containsKey(target)) {
          throw FormatException(
            'olcrtc legacy `$section.${entry.key}` conflicts with '
            'canonical `$target`.',
          );
        }
        node[target] = entry.value;
      }
    }

    flatten('auth', const {'provider': 'provider', 'token': 'provider-token'});
    flatten('room', const {'id': 'room', 'channel': 'room-channel'});
    flatten('crypto', const {'key': 'encryption-key'});
    flatten('net', const {'transport': 'transport', 'dns': 'dns-server'});
    flatten('engine', const {
      'name': 'engine',
      'url': 'engine-url',
      'token': 'engine-token',
    });

    final transport = _string(node['transport']);
    final legacySections = <String, Map<String, String>>{
      'video': const {
        'width': 'width',
        'height': 'height',
        'fps': 'fps',
        'bitrate': 'bitrate',
        'qr-size': 'fragment-size',
        'qr-recovery': 'qr-recovery',
        'codec': 'codec',
        'tile-module': 'tile-module',
        'tile-rs': 'tile-rs',
      },
      'vp8': const {'fps': 'fps', 'batch-size': 'batch-size'},
      'sei': const {
        'fps': 'fps',
        'batch-size': 'batch-size',
        'fragment-size': 'fragment-size',
        'ack-timeout-ms': 'ack-timeout',
      },
    };
    final expectedSection = switch (transport) {
      'videochannel' => 'video',
      'vp8channel' => 'vp8',
      'seichannel' => 'sei',
      _ => null,
    };
    for (final section in legacySections.keys) {
      if (!node.containsKey(section)) continue;
      if (section != expectedSection) {
        throw FormatException(
          'olcrtc legacy `$section` does not match transport `$transport`.',
        );
      }
      if (node.containsKey('transport-options')) {
        throw FormatException(
          'olcrtc legacy `$section` conflicts with canonical '
          '`transport-options`.',
        );
      }
      final source = _map(node.remove(section));
      if (source == null) {
        throw FormatException('olcrtc legacy `$section` must be a map.');
      }
      final options = <String, dynamic>{};
      for (final entry in source.entries) {
        if (section == 'video' && entry.key == 'hw') {
          throw const FormatException(
            'olcrtc `video.hw` is no longer supported.',
          );
        }
        final target = legacySections[section]![entry.key];
        if (target == null) {
          throw FormatException(
            'olcrtc legacy `$section.${entry.key}` is no longer supported.',
          );
        }
        options[target] = section == 'sei' && entry.key == 'ack-timeout-ms'
            ? '${entry.value}ms'
            : entry.value;
      }
      node['transport-options'] = options;
    }
    for (final (section, fields) in const [
      ('liveness', ['interval', 'timeout']),
      ('lifecycle', ['max-session-duration']),
      ('traffic', ['min-delay', 'max-delay']),
    ]) {
      final values = _map(node[section]);
      if (values == null) continue;
      for (final field in fields) {
        final value = values[field];
        if (value is int) values[field] = '${value}s';
      }
      node[section] = values;
    }
    return node;
  }

  Map<String, dynamic> _normalizeKeys(
    Map<dynamic, dynamic> input, {
    required String path,
  }) {
    final result = <String, dynamic>{};
    for (final entry in input.entries) {
      if (entry.key is! String) {
        throw FormatException('$path has a non-string field name.');
      }
      final original = entry.key as String;
      final canonical = original.replaceAll('_', '-');
      if (result.containsKey(canonical)) {
        throw FormatException(
          '$path `$original` conflicts with canonical `$canonical`.',
        );
      }
      final value = entry.value;
      result[canonical] = path == 'proxy' && canonical == 'headers'
          ? value
          : value is Map
              ? _normalizeKeys(value, path: '$path.$canonical')
              : value is List
                  ? [
                      for (var index = 0; index < value.length; index++)
                        value[index] is Map
                            ? _normalizeKeys(
                                value[index] as Map,
                                path: '$path.$canonical[$index]',
                              )
                            : value[index],
                    ]
                  : value;
    }
    return result;
  }

  void _move(
    Map<String, dynamic> map,
    String legacy,
    String canonical, {
    required String path,
  }) {
    if (!map.containsKey(legacy)) return;
    if (map.containsKey(canonical)) {
      throw FormatException(
        '$path `$legacy` conflicts with canonical `$canonical`.',
      );
    }
    map[canonical] = map.remove(legacy);
  }

  Map<String, dynamic>? _map(Object? value) => value is Map
      ? Map<String, dynamic>.from(value as Map<String, dynamic>)
      : null;

  String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}
