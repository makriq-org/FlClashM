import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/runtime/built_in_proxy_registry.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flutter/foundation.dart';

import 'olcrtc_config_validator.dart';

@immutable
class CompiledBuiltInProxyNodes {
  const CompiledBuiltInProxyNodes({
    required this.config,
    required this.nodes,
  });

  final Map<String, dynamic> config;
  final List<BuiltInProxyNodePlan> nodes;
}

class BuiltInProxyCompiler {
  const BuiltInProxyCompiler({
    this.registry = builtInProxyRegistry,
    this.olcRtcConfigValidator = const OlcRtcConfigValidator(),
  });

  final BuiltInProxyRegistry registry;
  final OlcRtcConfigValidator olcRtcConfigValidator;

  CompiledBuiltInProxyNodes compile({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
  }) {
    final normalizedConfig = _cloneConfig(rawConfig);
    final proxyEntries = normalizedConfig['proxies'];
    if (proxyEntries is! List) {
      _rejectLegacyRuntimeSelection(normalizedConfig);
      normalizedConfig.remove('x-flclashm-runtime');
      return CompiledBuiltInProxyNodes(
        config: normalizedConfig,
        nodes: const [],
      );
    }

    _rejectLegacyRuntimeSelection(normalizedConfig);
    normalizedConfig.remove('x-flclashm-runtime');

    final reservedPorts = _collectReservedPorts(
      config: normalizedConfig,
      patchConfig: patchConfig,
    );
    final compiledNodes = <BuiltInProxyNodePlan>[];

    for (var i = 0; i < proxyEntries.length; i++) {
      final proxy = proxyEntries[i];
      if (proxy is! Map) {
        continue;
      }
      final definition = _parseBuiltInProxyNode(proxy);
      if (definition == null) {
        continue;
      }

      final descriptor = registry.resolveSupported(definition.type);
      final listenPort = _allocateListenPort(
        definition: definition,
        descriptor: descriptor,
        reservedPorts: reservedPorts,
      );
      reservedPorts.add(listenPort);
      final nodeId = '${definition.type.label}-${definition.name.toMd5()}';
      final plan = _buildPlan(
        definition: definition,
        descriptor: descriptor,
        nodeId: nodeId,
        listenPort: listenPort,
      );
      compiledNodes.add(plan);
      proxyEntries[i] = plan.toProxyConfig();
    }

    return CompiledBuiltInProxyNodes(
      config: normalizedConfig,
      nodes: compiledNodes,
    );
  }

  BuiltInProxyNodeDefinition? _parseBuiltInProxyNode(dynamic proxy) {
    final normalizedProxy = _asStringKeyedMap(proxy);
    final type = BuiltInProxyTypeLabel.tryParse(
      _trimmedString(normalizedProxy['type']),
    );
    if (type == null) {
      return null;
    }

    final name = _trimmedString(normalizedProxy['name']);
    if (name == null) {
      throw const FormatException(
        'Built-in proxy nodes require a non-empty `name`.',
      );
    }

    return BuiltInProxyNodeDefinition(
      name: name,
      type: type,
      rawConfig: normalizedProxy,
    );
  }

  BuiltInProxyNodePlan _buildPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
  }) =>
      switch (definition.type) {
        BuiltInProxyType.naiveproxy => _buildNaiveProxyPlan(
            definition: definition,
            descriptor: descriptor,
            nodeId: nodeId,
            listenPort: listenPort,
          ),
        BuiltInProxyType.olcrtc => _buildOlcRtcPlan(
            definition: definition,
            descriptor: descriptor,
            nodeId: nodeId,
            listenPort: listenPort,
          ),
        BuiltInProxyType.byedpi => _buildByedpiPlan(
            definition: definition,
            descriptor: descriptor,
            nodeId: nodeId,
            listenPort: listenPort,
          ),
      };

  BuiltInProxyNodePlan _buildNaiveProxyPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
  }) {
    final rawConfig = Map<String, dynamic>.from(definition.rawConfig)
      ..remove('name')
      ..remove('type');
    final udp = rawConfig.remove('udp');
    if (udp == true) {
      throw const FormatException(
        'naiveproxy built-in nodes do not support `udp: true`.',
      );
    }
    if (rawConfig.containsKey('listen') ||
        rawConfig.containsKey('server') ||
        rawConfig.containsKey('port')) {
      throw const FormatException(
        'naiveproxy built-in nodes must not override `listen`, `server`, or `port`; those are owned by the client local-node contract.',
      );
    }

    final proxy = _trimmedString(rawConfig['proxy']);
    if (proxy == null) {
      throw const FormatException(
        'naiveproxy built-in nodes require a non-empty `proxy` field.',
      );
    }

    return BuiltInProxyNodePlan(
      nodeId: nodeId,
      name: definition.name,
      type: definition.type,
      listenHost: localhost,
      listenPort: listenPort,
      protocol: descriptor.protocol,
      udp: false,
      files: {
        'built-in-proxies/naiveproxy/$nodeId/config.json': json.encode(
          <String, dynamic>{
            'listen': 'socks://127.0.0.1:$listenPort',
            'proxy': proxy,
            ...rawConfig..remove('proxy'),
          },
        ),
      },
    );
  }

  BuiltInProxyNodePlan _buildOlcRtcPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
  }) {
    final rawConfig = _cloneConfig(definition.rawConfig)
      ..remove('name')
      ..remove('type');
    final udp = rawConfig.remove('udp');
    if (udp == true) {
      throw const FormatException(
        'olcrtc built-in nodes do not support `udp: true`.',
      );
    }
    if (rawConfig.containsKey('listen') ||
        rawConfig.containsKey('server') ||
        rawConfig.containsKey('port') ||
        rawConfig.containsKey('data')) {
      throw const FormatException(
        'olcrtc built-in nodes must not override `listen`, `server`, `port`, or `data`; those are owned by the client local-node contract.',
      );
    }
    rawConfig['data'] = 'data';

    final mode = _trimmedString(rawConfig['mode']);
    if (mode != null && mode.toLowerCase() != 'cnc') {
      throw const FormatException(
        'olcrtc built-in nodes support only client `mode: cnc` in FlClashM.',
      );
    }
    rawConfig['mode'] = 'cnc';

    final socks = _asStringKeyedMap(rawConfig['socks']);
    if (socks.containsKey('host') || socks.containsKey('port')) {
      throw const FormatException(
        'olcrtc built-in nodes must not override `socks.host` or `socks.port`; local bind is owned by the client.',
      );
    }
    socks['host'] = localhost;
    socks['port'] = listenPort;
    rawConfig['socks'] = socks;

    final crypto = _asStringKeyedMap(rawConfig['crypto']);
    if (crypto.containsKey('key_file')) {
      throw const FormatException(
        'olcrtc built-in nodes do not support `crypto.key_file` in v1.',
      );
    }

    _rejectUnsafeOlcRtcProfileOverrides(rawConfig['profiles']);
    olcRtcConfigValidator.validate(rawConfig);

    return BuiltInProxyNodePlan(
      nodeId: nodeId,
      name: definition.name,
      type: definition.type,
      listenHost: localhost,
      listenPort: listenPort,
      protocol: descriptor.protocol,
      udp: false,
      files: {
        'built-in-proxies/olcrtc/$nodeId/config.yaml': _encodeYaml(rawConfig),
      },
    );
  }

  void _rejectUnsafeOlcRtcProfileOverrides(dynamic profiles) {
    if (profiles == null) {
      return;
    }
    if (profiles is! List) {
      throw const FormatException(
        'olcrtc `profiles` must be a list.',
      );
    }

    void visit(dynamic value) {
      if (value is List) {
        value.forEach(visit);
        return;
      }
      if (value is! Map) {
        return;
      }

      final map = _asStringKeyedMap(value);
      final socks = map['socks'];
      if (socks is Map) {
        final socksMap = _asStringKeyedMap(socks);
        if (socksMap.containsKey('host') || socksMap.containsKey('port')) {
          throw const FormatException(
            'olcrtc profiles must not override `socks.host` or `socks.port`; local bind is owned by the client.',
          );
        }
      }
      final crypto = map['crypto'];
      if (crypto is Map && _asStringKeyedMap(crypto).containsKey('key_file')) {
        throw const FormatException(
          'olcrtc profiles must not use `crypto.key_file`.',
        );
      }

      map.values.forEach(visit);
    }

    visit(profiles);
  }

  BuiltInProxyNodePlan _buildByedpiPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
  }) {
    final rawConfig = _cloneConfig(definition.rawConfig)
      ..remove('name')
      ..remove('type');
    final udp = rawConfig.remove('udp');
    if (udp == true) {
      throw const FormatException(
        'byedpi built-in nodes do not support `udp: true`.',
      );
    }
    if (rawConfig.containsKey('listen') ||
        rawConfig.containsKey('server') ||
        rawConfig.containsKey('port') ||
        rawConfig.containsKey('ip')) {
      throw const FormatException(
        'byedpi built-in nodes must not override `listen`, `server`, `ip`, or `port`; those are owned by the client local-node contract.',
      );
    }

    final mode =
        (_trimmedString(rawConfig.remove('mode')) ?? 'manual').toLowerCase();
    if (mode != 'manual' && mode != 'auto') {
      throw const FormatException(
        'byedpi built-in nodes support only `mode: manual` or `mode: auto`.',
      );
    }

    final config = <String, dynamic>{
      'mode': mode,
      'listenHost': localhost,
      'listenPort': listenPort,
      'cache': _asStringKeyedMap(rawConfig.remove('cache')),
    };

    if (mode == 'manual') {
      final args = _trimmedString(rawConfig.remove('args'));
      if (args == null) {
        throw const FormatException(
          'byedpi manual nodes require a non-empty `args` field.',
        );
      }
      config['args'] = args;
    } else {
      final strategies = _stringList(rawConfig.remove('strategies'));
      final strategyList =
          _trimmedString(rawConfig.remove('strategy-list'))?.toLowerCase();
      if (strategies.isEmpty &&
          (strategyList == null || strategyList != 'byebyeedpi')) {
        throw const FormatException(
          'byedpi auto nodes require `strategies` or `strategy-list: byebyeedpi`.',
        );
      }
      final test = _asStringKeyedMap(rawConfig.remove('test'));
      final urls = _stringList(test['urls']);
      if (urls.isEmpty) {
        throw const FormatException(
          'byedpi auto nodes require non-empty `test.urls`.',
        );
      }
      config['strategies'] = strategies;
      config['strategyList'] = strategies.isEmpty ? strategyList : null;
      config['test'] = test;
    }

    if (rawConfig.isNotEmpty) {
      config['options'] = rawConfig;
    }

    return BuiltInProxyNodePlan(
      nodeId: nodeId,
      name: definition.name,
      type: definition.type,
      listenHost: localhost,
      listenPort: listenPort,
      protocol: descriptor.protocol,
      udp: false,
      files: {
        'built-in-proxies/byedpi/$nodeId/config.json': json.encode(config),
      },
    );
  }

  int _allocateListenPort({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required Set<int> reservedPorts,
  }) {
    final seed = definition.name.toMd5().codeUnits.fold<int>(
          0,
          (value, unit) => value + unit,
        );
    final rangeSize = descriptor.listenPortRangeSize;
    final rangeStart = descriptor.listenPortRangeStart;
    for (var offset = 0; offset < rangeSize; offset++) {
      final candidate = rangeStart + ((seed + offset) % rangeSize);
      if (!reservedPorts.contains(candidate)) {
        return candidate;
      }
    }
    throw FormatException(
      '${definition.type.label} built-in node `${definition.name}` could not reserve a local listener port without colliding with runtime ports.',
    );
  }

  Set<int> _collectReservedPorts({
    required Map<String, dynamic> config,
    required ClashConfig patchConfig,
  }) {
    final reserved = <int>{
      if (patchConfig.port > 0) patchConfig.port,
      if (patchConfig.socksPort > 0) patchConfig.socksPort,
      if (patchConfig.redirPort > 0) patchConfig.redirPort,
      if (patchConfig.tproxyPort > 0) patchConfig.tproxyPort,
      if (patchConfig.mixedPort > 0) patchConfig.mixedPort,
    };

    for (final key in const [
      'port',
      'socks-port',
      'redir-port',
      'tproxy-port',
      'mixed-port',
    ]) {
      final rawValue = config[key];
      if (rawValue is num && rawValue.toInt() > 0) {
        reserved.add(rawValue.toInt());
      }
    }
    return reserved;
  }

  void _rejectLegacyRuntimeSelection(Map<String, dynamic> rawConfig) {
    final runtimeConfig = rawConfig['x-flclashm-runtime'];
    if (runtimeConfig is! Map) {
      return;
    }
    final engine = _trimmedString(runtimeConfig['engine']);
    if (engine == null || engine.toLowerCase() != 'naiveproxy') {
      return;
    }
    throw const FormatException(
      'Legacy `x-flclashm-runtime.engine=naiveproxy` is no longer supported. Define a proxy entry with `type: naiveproxy` and include it in normal proxy groups or rules instead.',
    );
  }

  Map<String, dynamic> _cloneConfig(Map<String, dynamic> rawConfig) {
    final encoded = json.encode(rawConfig);
    return Map<String, dynamic>.from(json.decode(encoded) as Map);
  }

  Map<String, dynamic> _asStringKeyedMap(dynamic value) {
    if (value is! Map) {
      return <String, dynamic>{};
    }
    return value.map(
      (key, mapValue) => MapEntry(key.toString(), mapValue),
    );
  }

  String? _trimmedString(Object? value) {
    if (value is! String) {
      return null;
    }
    final normalizedValue = value.trim();
    return normalizedValue.isEmpty ? null : normalizedValue;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return [
      for (final item in value)
        if (_trimmedString(item) case final itemValue?) itemValue,
    ];
  }

  String _encodeYaml(Object? value, {int indent = 0}) {
    final padding = ' ' * indent;
    if (value is Map) {
      return value.entries.map((entry) {
        final key = entry.key.toString();
        final mapValue = entry.value;
        if (_isYamlScalar(mapValue)) {
          return '$padding$key: ${_encodeYamlScalar(mapValue)}';
        }
        return '$padding$key:\n${_encodeYaml(mapValue, indent: indent + 2)}';
      }).join('\n');
    }
    if (value is List) {
      if (value.isEmpty) {
        return '$padding[]';
      }
      return value.map((item) {
        if (_isYamlScalar(item)) {
          return '$padding- ${_encodeYamlScalar(item)}';
        }
        return '$padding-\n${_encodeYaml(item, indent: indent + 2)}';
      }).join('\n');
    }
    return '$padding${_encodeYamlScalar(value)}';
  }

  bool _isYamlScalar(Object? value) =>
      value == null || value is String || value is num || value is bool;

  String _encodeYamlScalar(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    return json.encode(value.toString());
  }
}
