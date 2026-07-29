part of '../built_in_proxy_compiler.dart';

extension NaiveProxyNodeCompiler on BuiltInProxyCompiler {
  BuiltInProxyNodePlan _buildNaiveProxyPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
    required NodeActivationConfig? activation,
  }) {
    final rawConfig = Map<String, dynamic>.from(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check')
      ..remove('activation');
    if (rawConfig.containsKey('proxy')) {
      throw const FormatException(
        'naiveproxy `proxy` is not supported. Use separate `server`, `port`, `username`, and `password` fields.',
      );
    }
    const fields = {
      'server',
      'port',
      'username',
      'password',
      'transport',
      'insecure-concurrency',
      'tunnel-timeout',
      'idle-timeout',
      'post-quantum',
      'headers',
      'host-resolver-rules',
    };
    final unknown =
        rawConfig.keys.where((key) => !fields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        'naiveproxy node `${definition.name}` has unknown or forbidden fields: '
        '${unknown.join(', ')}.',
      );
    }

    final transportValue = rawConfig['transport'];
    final transport =
        transportValue == null && !rawConfig.containsKey('transport')
            ? 'https'
            : _trimmedString(transportValue)?.toLowerCase();
    if (transport != 'https' && transport != 'quic') {
      throw const FormatException(
        'naiveproxy `transport` must be `https` or `quic`.',
      );
    }
    final server = _requiredNaiveProxyServer(rawConfig['server']);
    final port = _requiredPort(rawConfig['port'], 'naiveproxy `port`');
    final username = _requiredCredential(
      rawConfig['username'],
      'naiveproxy `username`',
    );
    final password = _requiredCredential(
      rawConfig['password'],
      'naiveproxy `password`',
    );
    final proxy = Uri(
      scheme: transport,
      userInfo:
          '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}',
      host: server,
      port: port,
    ).toString();
    final nativeConfig = <String, dynamic>{
      'listen': 'socks://127.0.0.1:$listenPort',
      'proxy': proxy,
    };
    if (rawConfig.containsKey('insecure-concurrency')) {
      final insecureConcurrency = rawConfig['insecure-concurrency'];
      if (insecureConcurrency == null) {
        throw const FormatException(
          'naiveproxy `insecure-concurrency` must be an integer from 1 to 4.',
        );
      }
      nativeConfig['insecure-concurrency'] = _boundedInt(
        insecureConcurrency,
        'naiveproxy `insecure-concurrency`',
        1,
        4,
      );
    }
    for (final field in const ['tunnel-timeout', 'idle-timeout']) {
      if (!rawConfig.containsKey(field)) continue;
      final duration = parsePublicConfigDuration(
        rawConfig[field],
        path: 'naiveproxy.$field',
        fallback: Duration.zero,
        maximum: const Duration(seconds: 2147483647),
      );
      if (duration.inMicroseconds % Duration.microsecondsPerSecond != 0) {
        throw FormatException(
          'naiveproxy `$field` must resolve to whole seconds.',
        );
      }
      nativeConfig[field] = duration.inSeconds;
    }
    final postQuantum = rawConfig['post-quantum'];
    if (rawConfig.containsKey('post-quantum') && postQuantum is! bool) {
      throw const FormatException(
        'naiveproxy `post-quantum` must be a boolean.',
      );
    }
    if (postQuantum == false) nativeConfig['no-post-quantum'] = true;
    if (rawConfig.containsKey('headers')) {
      final extraHeaders = _encodeNaiveProxyHeaders(rawConfig['headers']);
      if (extraHeaders != null) nativeConfig['extra-headers'] = extraHeaders;
    }
    if (rawConfig.containsKey('host-resolver-rules')) {
      final hostResolverRules = rawConfig['host-resolver-rules'];
      final rules = _trimmedString(hostResolverRules);
      if (rules == null || rules.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
        throw const FormatException(
          'naiveproxy `host-resolver-rules` must be a non-empty single-line string.',
        );
      }
      nativeConfig['host-resolver-rules'] = rules;
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
        'built-in-proxies/naiveproxy/$nodeId/config.json': json.encode(
          nativeConfig,
        ),
      },
    );
  }

  String _requiredNaiveProxyServer(Object? value) {
    final server = _trimmedString(value);
    if (server == null) {
      throw const FormatException(
        'naiveproxy built-in nodes require a non-empty `server` field.',
      );
    }
    if (server.contains(RegExp(r'[,/@?#\\\s]'))) {
      throw const FormatException(
        'naiveproxy `server` must be a host name or IP address, not a URI or proxy chain.',
      );
    }
    return server;
  }

  int _requiredPort(Object? value, String field) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() != value ||
        value.toInt() < 1 ||
        value.toInt() > 65535) {
      throw FormatException('$field must be an integer from 1 to 65535.');
    }
    return value.toInt();
  }

  String _requiredCredential(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field must be a non-empty string.');
    }
    return value;
  }

  String? _encodeNaiveProxyHeaders(Object? value) {
    if (value is! Map) {
      throw const FormatException('naiveproxy `headers` must be a map.');
    }
    final result = <String>[];
    for (final entry in value.entries) {
      final name = entry.key;
      final headerValue = entry.value;
      if (name is! String ||
          !RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name)) {
        throw const FormatException(
          'naiveproxy `headers` contains an invalid header name.',
        );
      }
      if (headerValue is! String ||
          headerValue.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
        throw FormatException(
          'naiveproxy header `$name` must have a string value without control characters.',
        );
      }
      result.add('$name: $headerValue');
    }
    return result.isEmpty ? null : result.join('\r\n');
  }
}
