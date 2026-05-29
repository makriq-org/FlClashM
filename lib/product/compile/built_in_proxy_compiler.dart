import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/runtime/built_in_proxy_registry.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flutter/foundation.dart';

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
  });

  final BuiltInProxyRegistry registry;

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
        BuiltInProxyType.byedpi ||
        BuiltInProxyType.olcrtc =>
          throw UnsupportedBuiltInProxyException(
            registry.buildUnsupportedMessage(descriptor),
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
}
