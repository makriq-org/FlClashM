import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/runtime/built_in_proxy_registry.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/connectivity_check.dart';
import 'package:flutter/foundation.dart';

import 'config_tree.dart';
import 'olcrtc_config_validator.dart';

@immutable
class CompiledBuiltInProxyNodes {
  const CompiledBuiltInProxyNodes({required this.config, required this.nodes});

  final Map<String, dynamic> config;
  final List<BuiltInProxyNodePlan> nodes;
}

const _defaultByedpiStrategyTestUrl = 'https://youtube.com/generate_204';

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
    String globalTestUrl = '',
  }) {
    final normalizedConfig = copyConfigTree(rawConfig);
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
      final connectivityCheck = _parseConnectivityCheck(
        definition: definition,
        config: normalizedConfig,
        globalTestUrl: globalTestUrl,
      );
      final plan = _buildPlan(
        definition: definition,
        descriptor: descriptor,
        nodeId: nodeId,
        listenPort: listenPort,
        connectivityCheck: connectivityCheck,
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
    required ConnectivityCheckConfig connectivityCheck,
  }) {
    final udp = _resolveUdp(definition: definition, descriptor: descriptor);
    return switch (definition.type) {
      BuiltInProxyType.naiveproxy => _buildNaiveProxyPlan(
          definition: definition,
          descriptor: descriptor,
          nodeId: nodeId,
          listenPort: listenPort,
          udp: udp,
          connectivityCheck: connectivityCheck,
        ),
      BuiltInProxyType.olcrtc => _buildOlcRtcPlan(
          definition: definition,
          descriptor: descriptor,
          nodeId: nodeId,
          listenPort: listenPort,
          udp: udp,
          connectivityCheck: connectivityCheck,
        ),
      BuiltInProxyType.byedpi => _buildByedpiPlan(
          definition: definition,
          descriptor: descriptor,
          nodeId: nodeId,
          listenPort: listenPort,
          udp: udp,
          connectivityCheck: connectivityCheck,
        ),
    };
  }

  bool _resolveUdp({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
  }) {
    if (!definition.rawConfig.containsKey('udp')) {
      return descriptor.defaultUdp;
    }
    final udp = definition.rawConfig['udp'];
    if (udp is! bool) {
      throw FormatException(
        '${definition.type.label} built-in node `${definition.name}` requires `udp` to be a boolean.',
      );
    }
    if (udp && !descriptor.supportsUdp) {
      throw FormatException(
        '${definition.type.label} built-in nodes do not support `udp: true`.',
      );
    }
    return udp;
  }

  BuiltInProxyNodePlan _buildNaiveProxyPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
  }) {
    final rawConfig = Map<String, dynamic>.from(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check');
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
      udp: udp,
      connectivityCheck: connectivityCheck,
      files: {
        'built-in-proxies/naiveproxy/$nodeId/config.json':
            json.encode(<String, dynamic>{
          'listen': 'socks://127.0.0.1:$listenPort',
          'proxy': proxy,
          ...rawConfig..remove('proxy'),
        }),
      },
    );
  }

  BuiltInProxyNodePlan _buildOlcRtcPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
  }) {
    final rawConfig = copyConfigTree(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check');
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
      udp: udp,
      connectivityCheck: connectivityCheck,
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
      throw const FormatException('olcrtc `profiles` must be a list.');
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
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
  }) {
    final rawConfig = copyConfigTree(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check');
    if (rawConfig.containsKey('test')) {
      throw const FormatException(
        'byedpi `test` is no longer supported. Rename it to `strategy-test`; connectivity checks belong in `connectivity-check`.',
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

    final modeValue = rawConfig.remove('mode');
    final mode = modeValue == null
        ? (rawConfig.containsKey('args') ? 'manual' : 'auto')
        : _trimmedString(modeValue)?.toLowerCase();
    if (mode != 'manual' && mode != 'auto') {
      throw const FormatException(
        'byedpi built-in nodes support only `mode: manual` or `mode: auto`.',
      );
    }

    final config = <String, dynamic>{
      'mode': mode,
      'listenHost': localhost,
      'listenPort': listenPort,
    };

    if (mode == 'manual') {
      if (rawConfig.containsKey('strategy-test')) {
        throw const FormatException(
          'byedpi `strategy-test` is allowed only for `mode: auto`.',
        );
      }
      final args = _trimmedString(rawConfig.remove('args'));
      if (args == null) {
        throw const FormatException(
          'byedpi manual nodes require a non-empty `args` field.',
        );
      }
      config['args'] = args;
    } else {
      final strategies = _strictStringList(
        rawConfig.remove('strategies'),
        'byedpi `strategies`',
      );
      final strategyListValue = rawConfig.remove('strategy-list');
      final strategyList = strategyListValue == null
          ? 'byebyeedpi'
          : _trimmedString(strategyListValue)?.toLowerCase();
      if (strategyList == null) {
        throw const FormatException(
          'byedpi `strategy-list` must be a non-empty string.',
        );
      }
      if (strategies.isNotEmpty && strategyListValue != null) {
        throw const FormatException(
          'byedpi auto nodes must use either `strategies` or `strategy-list`, not both.',
        );
      }
      if (strategies.isEmpty && strategyList != 'byebyeedpi') {
        throw const FormatException(
          'byedpi auto nodes require `strategies` or `strategy-list: byebyeedpi`.',
        );
      }
      final strategyTest = _optionalMap(
        rawConfig.remove('strategy-test'),
        'byedpi `strategy-test`',
      );
      var urls = _parseSafeUrls(
        strategyTest['urls'],
        label: 'byedpi `strategy-test.urls`',
        required: false,
      );
      if (urls.isEmpty) {
        urls = _parseSafeUrls(
          [_defaultByedpiStrategyTestUrl],
          label: 'bundled byedpi strategy test address',
          required: true,
        );
      }
      _validateStrategyTest(strategyTest);
      final selection = _optionalMap(
        rawConfig.remove('selection'),
        'byedpi `selection`',
      );
      _validateByedpiSelection(selection);
      final cache = _optionalMap(
        rawConfig.remove('cache'),
        'byedpi `cache`',
      );
      _validateByedpiCache(cache);
      final fallbackValue = rawConfig.remove('fallback-args');
      final fallbackArgs = _trimmedString(fallbackValue);
      if (fallbackValue != null && fallbackArgs == null) {
        throw const FormatException(
          'byedpi `fallback-args` must be a non-empty string.',
        );
      }
      config['strategies'] = strategies;
      config['strategyList'] = strategies.isEmpty ? strategyList : null;
      config['strategyTest'] = <String, dynamic>{
        ...strategyTest,
        'urls': urls.map((url) => url.toString()).toList(growable: false),
      };
      config['selection'] = selection;
      config['cache'] = cache;
      if (fallbackArgs != null) config['fallbackArgs'] = fallbackArgs;
    }

    if (rawConfig.isNotEmpty) {
      throw FormatException(
        'byedpi node `${definition.name}` has unknown or mode-incompatible fields: '
        '${rawConfig.keys.join(', ')}.',
      );
    }

    return BuiltInProxyNodePlan(
      nodeId: nodeId,
      name: definition.name,
      type: definition.type,
      listenHost: localhost,
      listenPort: listenPort,
      protocol: descriptor.protocol,
      udp: udp,
      connectivityCheck: connectivityCheck,
      files: {
        'built-in-proxies/byedpi/$nodeId/config.json': json.encode(config),
      },
    );
  }

  ConnectivityCheckConfig _parseConnectivityCheck({
    required BuiltInProxyNodeDefinition definition,
    required Map<String, dynamic> config,
    required String globalTestUrl,
  }) {
    final rawValue = definition.rawConfig['connectivity-check'];
    if (rawValue != null && rawValue is! Map) {
      throw FormatException(
        '${definition.type.label} node `${definition.name}` requires `connectivity-check` to be a map.',
      );
    }
    final raw = _asStringKeyedMap(rawValue);
    const fields = {
      'urls',
      'required',
      'timeout',
      'startup-timeout',
      'retry-interval',
      'requests',
      'concurrency',
      'min-success-ratio',
    };
    final unknown = raw.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        '${definition.type.label} node `${definition.name}` has unknown connectivity-check fields: ${unknown.join(', ')}.',
      );
    }
    final requiredValue = raw['required'] ?? false;
    if (requiredValue is! bool) {
      throw const FormatException(
          '`connectivity-check.required` must be a boolean.');
    }
    var urls = _parseSafeUrls(
      raw['urls'],
      label: '`connectivity-check.urls`',
      required: false,
    );
    if (urls.isEmpty) {
      urls = _resolveContainingGroupUrls(config, definition.name);
    }
    if (urls.isEmpty && globalTestUrl.trim().isNotEmpty) {
      urls = _parseSafeUrls(
        <String>[globalTestUrl],
        label: 'application connectivity address',
        required: false,
      );
    }
    if (requiredValue && urls.isEmpty) {
      throw FormatException(
        '${definition.type.label} node `${definition.name}` requires a connectivity-check address, but none was found in the node, containing groups, or application settings.',
      );
    }
    return ConnectivityCheckConfig(
      urls: urls,
      required: requiredValue,
      timeout:
          _seconds(raw['timeout'], 'timeout', 5, connectivityCheckMaxTimeout),
      startupTimeout: _seconds(
        raw['startup-timeout'],
        'startup-timeout',
        30,
        connectivityCheckMaxStartupTimeout,
      ),
      retryInterval: _seconds(
        raw['retry-interval'],
        'retry-interval',
        1,
        connectivityCheckMaxStartupTimeout,
      ),
      requests: _boundedInt(
          raw['requests'], 'requests', 1, connectivityCheckMaxRequests),
      concurrency: _boundedInt(
        raw['concurrency'],
        'concurrency',
        1,
        connectivityCheckMaxConcurrency,
      ),
      minSuccessRatio: _ratio(raw['min-success-ratio'], 'min-success-ratio'),
    );
  }

  List<Uri> _resolveContainingGroupUrls(
    Map<String, dynamic> config,
    String nodeName,
  ) {
    final values = config['proxy-groups'];
    if (values is! List) return const [];
    final groups = [
      for (final value in values)
        if (value is Map) _asStringKeyedMap(value),
    ];
    var members = <String>{nodeName};
    final visited = <String>{};
    while (members.isNotEmpty) {
      final parents = <String>{};
      for (final group in groups) {
        final name = _trimmedString(group['name']);
        if (name == null || visited.contains(name)) continue;
        final proxies = _stringList(group['proxies']);
        if (!proxies.any(members.contains)) continue;
        visited.add(name);
        final groupCheck = group['connectivity-check'];
        if (groupCheck != null && groupCheck is! Map) {
          throw FormatException(
            'Proxy group `$name` requires `connectivity-check` to be a map.',
          );
        }
        final checkUrls = _parseSafeUrls(
          groupCheck is Map ? _asStringKeyedMap(groupCheck)['urls'] : null,
          label: 'proxy group `$name` connectivity addresses',
          required: false,
        );
        if (checkUrls.isNotEmpty) return checkUrls;
        final url = _trimmedString(group['url']);
        if (url != null) {
          return _parseSafeUrls(
            <String>[url],
            label: 'proxy group `$name` url',
            required: false,
          );
        }
        parents.add(name);
      }
      members = parents;
    }
    return const [];
  }

  List<Uri> _parseSafeUrls(
    Object? value, {
    required String label,
    required bool required,
  }) {
    if (value == null) {
      if (required) throw FormatException('$label is required.');
      return const [];
    }
    if (value is! List) throw FormatException('$label must be a list.');
    if (value.length > connectivityCheckMaxUrls) {
      throw FormatException(
          '$label supports at most $connectivityCheckMaxUrls addresses.');
    }
    final result = <Uri>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty) {
        throw FormatException('$label must contain non-empty strings.');
      }
      final uri = Uri.tryParse(item.trim());
      if (uri == null || !isSafeConnectivityUri(uri)) {
        throw FormatException(
          '$label contains unsafe address `$item`; only public HTTP(S) addresses without credentials or fragments are allowed.',
        );
      }
      result.add(uri);
    }
    return List<Uri>.unmodifiable(result);
  }

  void _validateStrategyTest(Map<String, dynamic> value) {
    const fields = {
      'urls',
      'sni',
      'timeout',
      'requests',
      'concurrency',
      'min-success-ratio',
    };
    final unknown = value.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
          'byedpi `strategy-test` has unknown fields: ${unknown.join(', ')}.');
    }
    final sni = value['sni'];
    if (sni != null &&
        (sni is! String ||
            sni.trim().isEmpty ||
            sni.contains('/') ||
            sni.contains('@') ||
            sni.contains(':'))) {
      throw const FormatException(
          'byedpi `strategy-test.sni` must be a host name.');
    }
    _seconds(value['timeout'], 'strategy-test.timeout', 5,
        connectivityCheckMaxTimeout);
    _boundedInt(value['requests'], 'strategy-test.requests', 1,
        connectivityCheckMaxRequests);
    _boundedInt(
      value['concurrency'],
      'strategy-test.concurrency',
      4,
      connectivityCheckMaxConcurrency,
    );
    _ratio(value['min-success-ratio'], 'strategy-test.min-success-ratio');
  }

  void _validateByedpiSelection(Map<String, dynamic> value) {
    const fields = {'concurrency', 'foreground-timeout', 'background'};
    final unknown = value.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        'byedpi `selection` has unknown fields: ${unknown.join(', ')}.',
      );
    }
    _boundedInt(
      value['concurrency'],
      'selection.concurrency',
      4,
      connectivityCheckMaxConcurrency,
    );
    _seconds(
      value['foreground-timeout'],
      'selection.foreground-timeout',
      15,
      const Duration(minutes: 1),
    );
    final background = value['background'];
    if (background != null && background is! bool) {
      throw const FormatException(
        '`selection.background` must be a boolean.',
      );
    }
  }

  void _validateByedpiCache(Map<String, dynamic> value) {
    const fields = {
      'ttl',
      'recheck-after',
      'failure-threshold',
      'retry-after',
    };
    final unknown = value.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        'byedpi `cache` has unknown fields: ${unknown.join(', ')}.',
      );
    }
    const maximum = Duration(days: 365);
    final ttl = _seconds(value['ttl'], 'cache.ttl', 604800, maximum);
    final recheckAfter = _seconds(
      value['recheck-after'],
      'cache.recheck-after',
      86400,
      maximum,
    );
    _seconds(
      value['retry-after'],
      'cache.retry-after',
      300,
      maximum,
    );
    _boundedInt(
      value['failure-threshold'],
      'cache.failure-threshold',
      2,
      32,
    );
    if (recheckAfter > ttl) {
      throw const FormatException(
        '`cache.recheck-after` must not exceed `cache.ttl`.',
      );
    }
  }

  Map<String, dynamic> _optionalMap(Object? value, String label) {
    if (value == null) return <String, dynamic>{};
    if (value is! Map) throw FormatException('$label must be a map.');
    return _asStringKeyedMap(value);
  }

  List<String> _strictStringList(Object? value, String label) {
    if (value == null) return const [];
    if (value is! List) throw FormatException('$label must be a list.');
    final result = <String>[];
    for (final item in value) {
      final normalized = _trimmedString(item);
      if (normalized == null) {
        throw FormatException('$label must contain non-empty strings.');
      }
      result.add(normalized);
    }
    return List<String>.unmodifiable(result);
  }

  Duration _seconds(
      Object? value, String field, int fallback, Duration maximum) {
    final seconds = value ?? fallback;
    if (seconds is! num || seconds.toInt() != seconds || seconds <= 0) {
      throw FormatException('`$field` must be a positive integer.');
    }
    final result = Duration(seconds: seconds.toInt());
    if (result > maximum) {
      throw FormatException('`$field` exceeds the supported limit.');
    }
    return result;
  }

  int _boundedInt(Object? value, String field, int fallback, int maximum) {
    final number = value ?? fallback;
    if (number is! num ||
        number.toInt() != number ||
        number < 1 ||
        number > maximum) {
      throw FormatException('`$field` must be an integer from 1 to $maximum.');
    }
    return number.toInt();
  }

  double? _ratio(Object? value, String field) {
    if (value == null) return null;
    if (value is! num || value <= 0 || value > 1) {
      throw FormatException(
          '`$field` must be greater than 0 and no greater than 1.');
    }
    return value.toDouble();
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

  Map<String, dynamic> _asStringKeyedMap(dynamic value) {
    if (value is! Map) {
      return <String, dynamic>{};
    }
    return value.map((key, mapValue) => MapEntry(key.toString(), mapValue));
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
