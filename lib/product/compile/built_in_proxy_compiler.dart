import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/runtime/built_in_proxy_registry.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/connectivity_check.dart';
import 'package:flclashx/product/runtime/stormdns_release.dart';
import 'package:flutter/foundation.dart';

import 'built_in_proxy_normalizer.dart';
import 'byedpi_config_validator.dart';
import 'byedpi_strategy_sources.dart';
import 'config_tree.dart';
import 'naiveproxy_config_validator.dart';
import 'olcrtc_config_validator.dart';
import 'public_config_duration.dart';
import 'stormdns_config.dart';
import 'stormdns_config_validator.dart';
import 'stormdns_resolver_sources.dart';

part 'node_compilers/byedpi_compiler.dart';
part 'node_compilers/naiveproxy_compiler.dart';
part 'node_compilers/olcrtc_compiler.dart';
part 'node_compilers/stormdns_compiler.dart';

@immutable
class CompiledBuiltInProxyNodes {
  const CompiledBuiltInProxyNodes({required this.config, required this.nodes});

  final Map<String, dynamic> config;
  final List<BuiltInProxyNodePlan> nodes;
}

const _defaultByedpiStrategyTestUrl = 'https://youtube.com/generate_204';

@immutable
class _ContainingGroupResolution {
  const _ContainingGroupResolution({
    this.urls = const [],
    this.watchGroup = '',
    this.directGroups = const [],
  });

  final List<Uri> urls;
  final String watchGroup;
  final List<String> directGroups;
}

class BuiltInProxyCompiler {
  const BuiltInProxyCompiler({
    this.registry = builtInProxyRegistry,
    this.naiveProxyConfigValidator = const NaiveProxyConfigValidator(),
    this.byedpiConfigValidator = const ByedpiConfigValidator(),
    this.olcRtcConfigValidator = const OlcRtcConfigValidator(),
    this.stormDnsConfigValidator = const StormDnsConfigValidator(),
    this.stormDnsResolverParser = const StormDnsResolverSourceParser(),
    this.normalizer = const BuiltInProxyNormalizer(),
    this.byedpiStrategySourceParser = const ByedpiStrategySourceParser(),
  });

  final BuiltInProxyRegistry registry;
  final NaiveProxyConfigValidator naiveProxyConfigValidator;
  final ByedpiConfigValidator byedpiConfigValidator;
  final OlcRtcConfigValidator olcRtcConfigValidator;
  final StormDnsConfigValidator stormDnsConfigValidator;
  final StormDnsResolverSourceParser stormDnsResolverParser;
  final BuiltInProxyNormalizer normalizer;
  final ByedpiStrategySourceParser byedpiStrategySourceParser;

  void validateConfig(Map<String, dynamic> rawConfig) {
    _rejectLegacyRuntimeSelection(rawConfig);
    final normalized = copyConfigTree(rawConfig);
    _normalizeBuiltInProxyEntries(normalized);
    final proxyEntries = normalized['proxies'];
    if (proxyEntries is! List) {
      return;
    }
    for (final proxy in proxyEntries) {
      if (proxy is! Map) {
        continue;
      }
      final definition = _parseBuiltInProxyNode(proxy);
      if (definition != null) {
        final descriptor = registry.resolveSupported(definition.type);
        _rejectUnsupportedActivation(
          definition: definition,
          descriptor: descriptor,
        );
        _validateDefinition(definition);
      }
    }
  }

  CompiledBuiltInProxyNodes compile({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
    String globalTestUrl = '',
    bool copyConfig = true,
    bool validate = true,
    Map<Uri, StormDnsRemoteResolverList> stormDnsRemoteLists = const {},
    Map<Uri, ByedpiRemoteStrategyList> byedpiRemoteLists = const {},
  }) {
    final normalizedConfig = copyConfig ? copyConfigTree(rawConfig) : rawConfig;
    _normalizeBuiltInProxyEntries(normalizedConfig);
    final proxyEntries = normalizedConfig['proxies'];
    if (proxyEntries is! List) {
      if (validate) {
        validateConfig(normalizedConfig);
      }
      normalizedConfig.remove('x-flclashm-runtime');
      return CompiledBuiltInProxyNodes(
        config: normalizedConfig,
        nodes: const [],
      );
    }

    if (validate) {
      validateConfig(normalizedConfig);
    }
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
        descriptor: descriptor,
        config: normalizedConfig,
        globalTestUrl: globalTestUrl,
      );
      final activation = descriptor.supportsActivation
          ? _parseActivation(
              definition: definition,
              config: normalizedConfig,
              resolvedWakeUrls: connectivityCheck.urls,
            )
          : _rejectUnsupportedActivation(
              definition: definition,
              descriptor: descriptor,
            );
      final plan = _buildPlan(
        definition: definition,
        descriptor: descriptor,
        nodeId: nodeId,
        listenPort: listenPort,
        connectivityCheck: connectivityCheck,
        activation: activation,
        stormDnsRemoteLists: stormDnsRemoteLists,
        byedpiRemoteLists: byedpiRemoteLists,
      );
      compiledNodes.add(plan);
      proxyEntries[i] = plan.toProxyConfig();
    }

    return CompiledBuiltInProxyNodes(
      config: normalizedConfig,
      nodes: compiledNodes,
    );
  }

  void _normalizeBuiltInProxyEntries(Map<String, dynamic> config) {
    final proxies = config['proxies'];
    if (proxies is! List) return;
    for (var index = 0; index < proxies.length; index++) {
      final proxy = proxies[index];
      if (proxy is! Map) continue;
      final type = BuiltInProxyTypeLabel.tryParse(
        _trimmedString(proxy['type']),
      );
      if (type != null) proxies[index] = normalizer.normalize(proxy);
    }
  }

  void _validateDefinition(BuiltInProxyNodeDefinition definition) {
    switch (definition.type) {
      case BuiltInProxyType.naiveproxy:
        naiveProxyConfigValidator.validate(definition.rawConfig);
      case BuiltInProxyType.byedpi:
        byedpiConfigValidator.validate(definition.rawConfig);
      case BuiltInProxyType.olcrtc:
        olcRtcConfigValidator.validateBuiltInNode(definition.rawConfig);
      case BuiltInProxyType.stormdns:
        stormDnsConfigValidator.validateBuiltInNode(definition.rawConfig);
    }
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
    required NodeActivationConfig? activation,
    Map<Uri, StormDnsRemoteResolverList> stormDnsRemoteLists = const {},
    Map<Uri, ByedpiRemoteStrategyList> byedpiRemoteLists = const {},
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
          activation: activation,
        ),
      BuiltInProxyType.olcrtc => _buildOlcRtcPlan(
          definition: definition,
          descriptor: descriptor,
          nodeId: nodeId,
          listenPort: listenPort,
          udp: udp,
          connectivityCheck: connectivityCheck,
          activation: activation!,
        ),
      BuiltInProxyType.byedpi => _buildByedpiPlan(
          definition: definition,
          descriptor: descriptor,
          nodeId: nodeId,
          listenPort: listenPort,
          udp: udp,
          connectivityCheck: connectivityCheck,
          activation: activation,
          remoteLists: byedpiRemoteLists,
        ),
      BuiltInProxyType.stormdns => _buildStormDnsPlan(
          definition: definition,
          descriptor: descriptor,
          nodeId: nodeId,
          listenPort: listenPort,
          udp: udp,
          connectivityCheck: connectivityCheck,
          activation: activation!,
          remoteLists: stormDnsRemoteLists,
        ),
    };
  }

  Map<Uri, Duration> collectStormDnsRemoteLists(
    Map<String, dynamic> rawConfig,
  ) {
    final result = <Uri, Duration>{};
    final proxyEntries = rawConfig['proxies'];
    if (proxyEntries is! List) return result;
    for (final proxy in proxyEntries) {
      if (proxy is! Map) continue;
      if (BuiltInProxyTypeLabel.tryParse(_trimmedString(proxy['type'])) !=
          BuiltInProxyType.stormdns) {
        continue;
      }
      final normalized = normalizer.normalize(proxy);
      final List<Uri> urls;
      try {
        urls = stormDnsResolverParser.parseRemoteListUrls(
          normalized['resolvers'],
          label: 'stormdns `resolvers`',
        );
      } catch (_) {
        // Malformed lists are reported by the normal validation pass.
        continue;
      }
      final policy = normalized['resolver-policy'];
      final refreshValue =
          policy is Map ? _asStringKeyedMap(policy)['refresh'] : null;
      final refresh = refreshValue is String
          ? parseStormDnsDuration(refreshValue) ?? const Duration(hours: 24)
          : const Duration(hours: 24);
      for (final url in urls) {
        final existing = result[url];
        if (existing == null &&
            result.length >= stormDnsMaxRemoteResolverLists) {
          throw const FormatException(
            'A profile may reference at most '
            '$stormDnsMaxRemoteResolverLists distinct StormDNS resolver lists.',
          );
        }
        if (existing == null || refresh < existing) {
          result[url] = refresh;
        }
      }
    }
    return result;
  }

  Map<Uri, Duration> collectByedpiRemoteLists(Map<String, dynamic> rawConfig) {
    final result = <Uri, Duration>{};
    final proxies = rawConfig['proxies'];
    if (proxies is! List) return result;
    for (final proxy in proxies) {
      if (proxy is! Map) continue;
      if (BuiltInProxyTypeLabel.tryParse(_trimmedString(proxy['type'])) !=
          BuiltInProxyType.byedpi) {
        continue;
      }
      final normalized = normalizer.normalize(proxy);
      final mode = _trimmedString(normalized['mode']) ??
          (normalized.containsKey('strategy') ? 'manual' : 'auto');
      if (mode != 'auto') continue;
      for (final url in byedpiStrategySourceParser.remoteUrls(
        normalized['strategies'],
      )) {
        if (!result.containsKey(url) &&
            result.length >= byedpiMaxRemoteStrategyLists) {
          throw const FormatException(
            'A profile may reference at most '
            '$byedpiMaxRemoteStrategyLists ByeDPI strategy lists.',
          );
        }
        result[url] = const Duration(days: 1);
      }
    }
    return result;
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

  NodeActivationConfig _parseActivation({
    required BuiltInProxyNodeDefinition definition,
    required Map<String, dynamic> config,
    required List<Uri> resolvedWakeUrls,
  }) {
    final nodeLabel = '${definition.type.label} node `${definition.name}`';
    final rawValue = definition.rawConfig['activation'];
    Map<String, dynamic> raw;
    String modeValue;
    if (rawValue == null) {
      raw = <String, dynamic>{};
      modeValue = 'auto';
    } else if (rawValue is String) {
      raw = <String, dynamic>{};
      modeValue = rawValue.trim().toLowerCase();
    } else if (rawValue is Map) {
      raw = _asStringKeyedMap(rawValue);
      const fields = {'mode', 'wake', 'sleep'};
      final unknown = raw.keys.where((key) => !fields.contains(key)).toList();
      if (unknown.isNotEmpty) {
        throw FormatException(
          '$nodeLabel has unknown activation fields: '
          '${unknown.join(', ')}.',
        );
      }
      final parsedMode = raw['mode'];
      modeValue = parsedMode == null
          ? 'auto'
          : _trimmedString(parsedMode)?.toLowerCase() ?? '';
    } else {
      throw FormatException(
        '$nodeLabel requires `activation` to be `auto`, '
        '`always`, or a map.',
      );
    }

    final mode = switch (modeValue) {
      'auto' => NodeActivationMode.auto,
      'always' => NodeActivationMode.always,
      _ => throw FormatException(
          '$nodeLabel supports only '
          '`activation.mode: auto` or `activation.mode: always`.',
        ),
    };
    final wake = _optionalMap(raw['wake'], '`activation.wake`');
    const wakeFields = {'urls', 'interval', 'failures', 'retry-after'};
    final unknownWake =
        wake.keys.where((key) => !wakeFields.contains(key)).toList();
    if (unknownWake.isNotEmpty) {
      throw FormatException(
        '$nodeLabel has unknown activation.wake fields: '
        '${unknownWake.join(', ')}.',
      );
    }
    final sleep = _optionalMap(raw['sleep'], '`activation.sleep`');
    const sleepFields = {'idle'};
    final unknownSleep =
        sleep.keys.where((key) => !sleepFields.contains(key)).toList();
    if (unknownSleep.isNotEmpty) {
      throw FormatException(
        '$nodeLabel has unknown activation.sleep fields: '
        '${unknownSleep.join(', ')}.',
      );
    }

    var wakeUrls = _parseSafeUrls(
      wake['urls'],
      label: '`activation.wake.urls`',
      required: false,
    );
    if (wakeUrls.isEmpty) wakeUrls = resolvedWakeUrls;
    final groups = _resolveContainingGroups(config, definition.name);
    if (mode == NodeActivationMode.auto && groups.directGroups.isEmpty) {
      throw FormatException(
        '$nodeLabel uses automatic activation but is not '
        'a direct member of any proxy group. Add it to a group or use '
        '`activation: always`.',
      );
    }
    if (mode == NodeActivationMode.auto && wakeUrls.isEmpty) {
      throw FormatException(
        '$nodeLabel uses automatic activation but no wake '
        'address was found in activation.wake.urls, connectivity-check, '
        'containing groups, or application settings.',
      );
    }

    return NodeActivationConfig(
      mode: mode,
      wakeUrls: List<Uri>.unmodifiable(wakeUrls),
      wakeInterval: _seconds(
        wake['interval'],
        'activation.wake.interval',
        30,
        const Duration(hours: 1),
      ),
      wakeFailures: _boundedInt(
        wake['failures'],
        'activation.wake.failures',
        2,
        10,
      ),
      wakeRetryAfter: _seconds(
        wake['retry-after'],
        'activation.wake.retry-after',
        300,
        const Duration(days: 1),
      ),
      sleepIdle: _nonNegativeSeconds(
        sleep['idle'],
        'activation.sleep.idle',
        900,
        const Duration(days: 1),
      ),
      watchGroup: groups.watchGroup,
      containingGroups: List<String>.unmodifiable(groups.directGroups),
    );
  }

  NodeActivationConfig? _rejectUnsupportedActivation({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
  }) {
    if (descriptor.supportsActivation) return null;
    if (definition.rawConfig.containsKey('activation')) {
      throw FormatException(
        '${definition.type.label} node `${definition.name}` does not support '
        '`activation`.',
      );
    }
    return null;
  }

  ConnectivityCheckConfig _parseConnectivityCheck({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
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
        '`connectivity-check.required` must be a boolean.',
      );
    }
    var urls = _parseSafeUrls(
      raw['urls'],
      label: '`connectivity-check.urls`',
      required: false,
    );
    if (urls.isEmpty) {
      urls = _resolveContainingGroups(config, definition.name).urls;
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
      timeout: _seconds(
        raw['timeout'],
        'timeout',
        5,
        connectivityCheckMaxTimeout,
      ),
      startupTimeout: _seconds(
        raw['startup-timeout'],
        'startup-timeout',
        descriptor.defaultStartupTimeout.inSeconds,
        connectivityCheckMaxStartupTimeout,
      ),
      retryInterval: _seconds(
        raw['retry-interval'],
        'retry-interval',
        1,
        connectivityCheckMaxStartupTimeout,
      ),
      requests: _boundedInt(
        raw['requests'],
        'requests',
        1,
        connectivityCheckMaxRequests,
      ),
      concurrency: _boundedInt(
        raw['concurrency'],
        'concurrency',
        1,
        connectivityCheckMaxConcurrency,
      ),
      minSuccessRatio: _ratio(raw['min-success-ratio'], 'min-success-ratio'),
    );
  }

  _ContainingGroupResolution _resolveContainingGroups(
    Map<String, dynamic> config,
    String nodeName,
  ) {
    final values = config['proxy-groups'];
    if (values is! List) return const _ContainingGroupResolution();
    final groups = [
      for (final value in values)
        if (value is Map) _asStringKeyedMap(value),
    ];
    final directGroups = <String>[];
    for (final group in groups) {
      final name = _trimmedString(group['name']);
      if (name != null && _stringList(group['proxies']).contains(nodeName)) {
        directGroups.add(name);
      }
    }
    var members = <String>{nodeName};
    final visited = <String>{};
    var resolvedUrls = const <Uri>[];
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
        if (checkUrls.isNotEmpty) {
          resolvedUrls = checkUrls;
          members = const {};
          break;
        }
        final url = _trimmedString(group['url']);
        if (url != null) {
          resolvedUrls = _parseSafeUrls(
            <String>[url],
            label: 'proxy group `$name` url',
            required: false,
          );
          members = const {};
          break;
        }
        parents.add(name);
      }
      if (resolvedUrls.isNotEmpty) break;
      members = parents;
    }
    return _ContainingGroupResolution(
      urls: resolvedUrls,
      watchGroup: directGroups.isEmpty ? '' : directGroups.first,
      directGroups: List<String>.unmodifiable(directGroups),
    );
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
        '$label supports at most $connectivityCheckMaxUrls addresses.',
      );
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

  Map<String, dynamic> _optionalMap(Object? value, String label) {
    if (value == null) return <String, dynamic>{};
    if (value is! Map) throw FormatException('$label must be a map.');
    return _asStringKeyedMap(value);
  }

  Duration _seconds(
    Object? value,
    String field,
    int fallback,
    Duration maximum,
  ) {
    final duration = parsePublicConfigDuration(
      value,
      path: field,
      fallback: Duration(seconds: fallback),
      maximum: maximum,
    );
    if (duration.inMicroseconds % Duration.microsecondsPerSecond != 0) {
      throw FormatException('`$field` must resolve to whole seconds.');
    }
    return duration;
  }

  Duration _nonNegativeSeconds(
    Object? value,
    String field,
    int fallback,
    Duration maximum,
  ) {
    final duration = parsePublicConfigDuration(
      value,
      path: field,
      fallback: Duration(seconds: fallback),
      maximum: maximum,
      allowZero: true,
    );
    if (duration.inMicroseconds % Duration.microsecondsPerSecond != 0) {
      throw FormatException('`$field` must resolve to whole seconds.');
    }
    return duration;
  }

  int _boundedInt(Object? value, String field, int fallback, int maximum) {
    final number = value ?? fallback;
    if (number is! num ||
        !number.isFinite ||
        number.toInt() != number ||
        number < 1 ||
        number > maximum) {
      throw FormatException('`$field` must be an integer from 1 to $maximum.');
    }
    return number.toInt();
  }

  double? _ratio(Object? value, String field) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value <= 0 || value > 1) {
      throw FormatException(
        '`$field` must be greater than 0 and no greater than 1.',
      );
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
      if (rawValue is num && rawValue.isFinite && rawValue.toInt() > 0) {
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
