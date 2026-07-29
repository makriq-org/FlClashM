part of '../built_in_proxy_compiler.dart';

extension ByedpiNodeCompiler on BuiltInProxyCompiler {
  BuiltInProxyNodePlan _buildByedpiPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
    required NodeActivationConfig? activation,
    required Map<Uri, ByedpiRemoteStrategyList> remoteLists,
  }) {
    final rawConfig = copyConfigTree(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check')
      ..remove('activation');
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
        ? (rawConfig.containsKey('strategy') ? 'manual' : 'auto')
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
      final strategy = _trimmedString(rawConfig.remove('strategy'));
      if (strategy == null) {
        throw const FormatException(
          'byedpi manual nodes require a non-empty `strategy` field.',
        );
      }
      config['args'] = strategy;
    } else {
      final sources = byedpiStrategySourceParser.parse(
        rawConfig.remove('strategies'),
      );
      final strategies = expandByedpiStrategies(
        sources: sources,
        remoteLists: remoteLists,
      );
      if (strategies.isEmpty) {
        throw const FormatException(
          'byedpi auto node resolved an empty `strategies` list.',
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
        rawConfig.remove('strategy-selection'),
        'byedpi `strategy-selection`',
      );
      _validateByedpiSelection(selection);
      final cache = _optionalMap(
        selection.remove('cache'),
        'byedpi selection `cache`',
      );
      _validateByedpiCache(cache);
      final fallbackValue = selection.remove('fallback-strategy');
      final fallbackArgs = _trimmedString(fallbackValue);
      if (fallbackValue != null && fallbackArgs == null) {
        throw const FormatException(
          'byedpi `fallback-strategy` must be a non-empty string.',
        );
      }
      final retryAfter = selection.remove('retry-after');
      final onlyBundled =
          strategies.length == 1 && strategies.single == 'builtin:byebyeedpi';
      config['strategies'] = onlyBundled ? const <String>[] : strategies;
      config['strategyList'] = onlyBundled ? 'byebyeedpi' : null;
      final nativeTest = Map<String, dynamic>.from(strategyTest);
      final resolver = nativeTest.remove('dns-resolver');
      final requestConcurrency = nativeTest.remove('request-concurrency');
      final testTimeout = nativeTest.remove('timeout');
      if (testTimeout != null) {
        nativeTest['timeout'] = _seconds(
          testTimeout,
          'strategy-test.timeout',
          5,
          connectivityCheckMaxTimeout,
        ).inSeconds;
      }
      if (resolver != null) nativeTest['resolver'] = resolver;
      if (requestConcurrency != null) {
        nativeTest['concurrency'] = requestConcurrency;
      }
      config['strategyTest'] = <String, dynamic>{
        ...nativeTest,
        'urls': urls.map((url) => url.toString()).toList(growable: false),
      };
      final selectionConcurrency = selection.remove('strategy-concurrency');
      final startupTimeout = selection.remove('startup-timeout');
      final background = selection.remove('continue-in-background');
      config['selection'] = <String, dynamic>{
        if (selectionConcurrency != null) 'concurrency': selectionConcurrency,
        if (startupTimeout != null)
          'foreground-timeout': _seconds(
            startupTimeout,
            'strategy-selection.startup-timeout',
            15,
            const Duration(minutes: 1),
          ).inSeconds,
        if (background != null) 'background': background,
      };
      config['cache'] = <String, dynamic>{
        if (cache['ttl'] != null)
          'ttl': _seconds(
            cache['ttl'],
            'strategy-selection.cache.ttl',
            604800,
            const Duration(days: 365),
          ).inSeconds,
        if (cache['recheck-after'] != null)
          'recheck-after': _seconds(
            cache['recheck-after'],
            'strategy-selection.cache.recheck-after',
            86400,
            const Duration(days: 365),
          ).inSeconds,
        if (cache['failure-threshold'] != null)
          'failure-threshold': cache['failure-threshold'],
        if (retryAfter != null)
          'retry-after': _seconds(
            retryAfter,
            'strategy-selection.retry-after',
            300,
            const Duration(days: 365),
          ).inSeconds,
      };
      if (fallbackArgs != null) config['fallbackArgs'] = fallbackArgs;
      if (selection.isNotEmpty) {
        throw FormatException(
          'byedpi strategy-selection has unknown fields: '
          '${selection.keys.join(', ')}.',
        );
      }
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
      activation: activation,
      files: {
        'built-in-proxies/byedpi/$nodeId/config.json': json.encode(config),
      },
    );
  }

  void _validateStrategyTest(Map<String, dynamic> value) {
    const fields = {
      'urls',
      'sni',
      'dns-resolver',
      'timeout',
      'requests',
      'request-concurrency',
      'min-success-ratio',
    };
    final unknown = value.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        'byedpi `strategy-test` has unknown fields: ${unknown.join(', ')}.',
      );
    }
    _validateStrategyTestResolver(value['dns-resolver']);
    final sni = value['sni'];
    if (sni != null &&
        (sni is! String ||
            sni.trim().isEmpty ||
            sni.contains('/') ||
            sni.contains('@') ||
            sni.contains(':'))) {
      throw const FormatException(
        'byedpi `strategy-test.sni` must be a host name.',
      );
    }
    _seconds(
      value['timeout'],
      'strategy-test.timeout',
      5,
      connectivityCheckMaxTimeout,
    );
    _boundedInt(
      value['requests'],
      'strategy-test.requests',
      1,
      connectivityCheckMaxRequests,
    );
    _boundedInt(
      value['request-concurrency'],
      'strategy-test.request-concurrency',
      4,
      connectivityCheckMaxConcurrency,
    );
    _ratio(value['min-success-ratio'], 'strategy-test.min-success-ratio');
  }

  void _validateStrategyTestResolver(Object? value) {
    if (value == null) return;
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException(
        'byedpi `strategy-test.dns-resolver` must be a public https DoH URL or `system`.',
      );
    }
    final resolver = value.trim();
    if (resolver.toLowerCase() == 'system') return;
    final uri = Uri.tryParse(resolver);
    if (uri == null || uri.scheme != 'https' || !isSafeConnectivityUri(uri)) {
      throw const FormatException(
        'byedpi `strategy-test.dns-resolver` must be a public https DoH URL or `system`.',
      );
    }
  }

  void _validateByedpiSelection(Map<String, dynamic> value) {
    const fields = {
      'strategy-concurrency',
      'startup-timeout',
      'continue-in-background',
      'fallback-strategy',
      'retry-after',
      'cache',
    };
    final unknown = value.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        'byedpi `strategy-selection` has unknown fields: ${unknown.join(', ')}.',
      );
    }
    _boundedInt(
      value['strategy-concurrency'],
      'strategy-selection.strategy-concurrency',
      4,
      connectivityCheckMaxConcurrency,
    );
    _seconds(
      value['startup-timeout'],
      'strategy-selection.startup-timeout',
      15,
      const Duration(minutes: 1),
    );
    final background = value['continue-in-background'];
    if (background != null && background is! bool) {
      throw const FormatException(
        '`strategy-selection.continue-in-background` must be a boolean.',
      );
    }
  }

  void _validateByedpiCache(Map<String, dynamic> value) {
    const fields = {'ttl', 'recheck-after', 'failure-threshold'};
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
    _boundedInt(value['failure-threshold'], 'cache.failure-threshold', 2, 32);
    if (recheckAfter > ttl) {
      throw const FormatException(
        '`cache.recheck-after` must not exceed `cache.ttl`.',
      );
    }
  }
}
