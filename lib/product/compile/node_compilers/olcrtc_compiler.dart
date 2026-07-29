part of '../built_in_proxy_compiler.dart';

extension OlcRtcNodeCompiler on BuiltInProxyCompiler {
  BuiltInProxyNodePlan _buildOlcRtcPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
    required NodeActivationConfig activation,
  }) {
    final rawConfig = copyConfigTree(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check')
      ..remove('activation');
    olcRtcConfigValidator.validate(definition.rawConfig);
    final provider = rawConfig.remove('provider');
    final providerToken = rawConfig.remove('provider-token');
    final room = rawConfig.remove('room');
    final roomChannel = rawConfig.remove('room-channel');
    final encryptionKey = rawConfig.remove('encryption-key');
    final transport = rawConfig.remove('transport');
    final dnsServer = rawConfig.remove('dns-server');
    final engine = rawConfig.remove('engine');
    final engineUrl = rawConfig.remove('engine-url');
    final engineToken = rawConfig.remove('engine-token');
    final options = _optionalMap(
      rawConfig.remove('transport-options'),
      'olcrtc `transport-options`',
    );

    final native = <String, dynamic>{
      'mode': 'cnc',
      'data': 'data',
      'auth': {
        'provider': provider,
        if (providerToken != null) 'token': providerToken,
      },
      if (room != null || roomChannel != null)
        'room': {
          if (room != null) 'id': room,
          if (roomChannel != null) 'channel': roomChannel,
        },
      'crypto': {'key': encryptionKey},
      'net': {'transport': transport, 'dns': dnsServer},
      'socks': {'host': localhost, 'port': listenPort},
      if (engine != null)
        'engine': {'name': engine, 'url': engineUrl, 'token': engineToken},
    };
    if (transport == 'videochannel') {
      native['video'] = {
        ..._olcRtcNativeOptions(options, const {
          'fragment-size': 'qr_size',
          'qr-recovery': 'qr_recovery',
          'tile-module': 'tile_module',
          'tile-rs': 'tile_rs',
        }),
        // The pinned runtime requires this field. Hardware selection is not a
        // public capability on Android, so the compiler owns the safe value.
        'hw': 'none',
      };
    } else if (transport == 'vp8channel') {
      native['vp8'] = _olcRtcNativeOptions(options, const {
        'batch-size': 'batch_size',
      });
    } else if (transport == 'seichannel') {
      final nativeOptions = _olcRtcNativeOptions(options, const {
        'batch-size': 'batch_size',
        'fragment-size': 'fragment_size',
      });
      nativeOptions['ack_timeout_ms'] = parsePublicConfigDuration(
        options['ack-timeout'],
        path: 'olcrtc.transport-options.ack-timeout',
        fallback: const Duration(seconds: 2),
        maximum: const Duration(days: 1),
      ).inMilliseconds;
      nativeOptions.remove('ack-timeout');
      native['sei'] = nativeOptions;
    }
    for (final section in const ['liveness', 'lifecycle', 'traffic']) {
      final value = rawConfig.remove(section);
      if (value is Map) {
        final nativeSection = <String, dynamic>{
          for (final entry in value.entries)
            '${entry.key}'.replaceAll('-', '_'): entry.value,
        };
        final durationFields = switch (section) {
          'liveness' => const ['interval', 'timeout'],
          'lifecycle' => const ['max_session_duration'],
          'traffic' => const ['min_delay', 'max_delay'],
          _ => const <String>[],
        };
        for (final field in durationFields) {
          if (!nativeSection.containsKey(field)) continue;
          nativeSection[field] = durationToGoString(
            parsePublicConfigDuration(
              nativeSection[field],
              path: 'olcrtc.$section.${field.replaceAll('_', '-')}',
              fallback: Duration.zero,
              maximum: const Duration(days: 365),
              allowZero: section == 'traffic',
            ),
          );
        }
        native[section] = nativeSection;
      }
    }
    if (rawConfig.containsKey('debug')) {
      native['debug'] = rawConfig.remove('debug');
    }
    if (rawConfig.isNotEmpty) {
      throw FormatException(
        'olcrtc node `${definition.name}` has unknown fields: '
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
        'built-in-proxies/olcrtc/$nodeId/config.yaml': _encodeYaml(native),
      },
    );
  }

  Map<String, dynamic> _olcRtcNativeOptions(
    Map<String, dynamic> options,
    Map<String, String> aliases,
  ) =>
      {
        for (final entry in options.entries)
          aliases[entry.key] ?? entry.key: entry.value,
      };
}
