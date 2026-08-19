import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'public_config_duration.dart';
import 'strict_config_schema_validator.dart';

class OlcRtcConfigValidator {
  const OlcRtcConfigValidator({
    this.schemaValidator = const StrictConfigSchemaValidator(),
  });

  final StrictConfigSchemaValidator schemaValidator;

  static const supportedProviders = {'jitsi', 'telemost', 'wbstream', 'none'};
  static const supportedTransports = {
    'datachannel',
    'vp8channel',
    'seichannel',
    'videochannel',
  };

  void validateBuiltInNode(Map<String, dynamic> config) {
    schemaValidator.validate(
      config,
      schema: builtInProxySchemas[BuiltInProxyType.olcrtc]!,
    );
    validate(config);
  }

  void validate(Map<String, dynamic> config) {
    final provider = _requiredString(config['provider'], 'olcrtc.provider');
    if (!supportedProviders.contains(provider)) {
      throw FormatException('olcrtc provider `$provider` is unsupported.');
    }
    final room = _string(config['room']);
    final engine = _string(config['engine']);
    final engineUrl = _string(config['engine-url']);
    final engineToken = _string(config['engine-token']);
    if (provider == 'none') {
      if (engine == null || engineUrl == null || engineToken == null) {
        throw const FormatException(
          'olcrtc provider `none` requires `engine`, `engine-url`, and '
          '`engine-token`.',
        );
      }
    } else {
      if (room == null) {
        throw const FormatException(
          'olcrtc `room` is required when provider is not `none`.',
        );
      }
      if (engine != null || engineUrl != null || engineToken != null) {
        throw const FormatException(
          'olcrtc direct engine fields are allowed only with `provider: none`.',
        );
      }
    }

    final key = _requiredString(
      config['encryption-key'],
      'olcrtc.encryption-key',
    );
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key)) {
      throw const FormatException(
        'olcrtc `encryption-key` must contain exactly 64 hexadecimal characters.',
      );
    }
    final dns = _requiredString(config['dns-server'], 'olcrtc.dns-server');
    if (dns != 'system' && !_isHostPort(dns)) {
      throw const FormatException(
        'olcrtc `dns-server` must use `host:port` or `system`.',
      );
    }

    final transport = _requiredString(config['transport'], 'olcrtc.transport');
    if (!supportedTransports.contains(transport)) {
      throw FormatException('olcrtc transport `$transport` is unsupported.');
    }
    final options = _map(config['transport-options']);
    if (transport == 'datachannel') {
      if (config.containsKey('transport-options')) {
        throw const FormatException(
          'olcrtc `transport-options` is forbidden for `datachannel`.',
        );
      }
    } else {
      _validateTransportOptions(transport, options);
    }

    final liveness = _map(config['liveness']);
    parsePublicConfigDuration(
      liveness['interval'],
      path: 'olcrtc.liveness.interval',
      fallback: const Duration(seconds: 10),
      maximum: const Duration(days: 1),
    );
    parsePublicConfigDuration(
      liveness['timeout'],
      path: 'olcrtc.liveness.timeout',
      fallback: const Duration(seconds: 15),
      maximum: const Duration(days: 1),
    );
    final lifecycle = _map(config['lifecycle']);
    if (lifecycle.containsKey('max-session-duration')) {
      parsePublicConfigDuration(
        lifecycle['max-session-duration'],
        path: 'olcrtc.lifecycle.max-session-duration',
        fallback: Duration.zero,
        maximum: const Duration(days: 365),
      );
    }
    final traffic = _map(config['traffic']);
    final minDelay = parsePublicConfigDuration(
      traffic['min-delay'],
      path: 'olcrtc.traffic.min-delay',
      fallback: Duration.zero,
      maximum: const Duration(days: 1),
      allowZero: true,
    );
    final maxDelay = parsePublicConfigDuration(
      traffic['max-delay'],
      path: 'olcrtc.traffic.max-delay',
      fallback: Duration.zero,
      maximum: const Duration(days: 1),
      allowZero: true,
    );
    if (maxDelay != Duration.zero && maxDelay < minDelay) {
      throw const FormatException(
        'olcrtc `traffic.max-delay` must not be less than `min-delay`.',
      );
    }
    final payload = traffic['max-payload-size'];
    if (payload is int && payload != 0 && payload < 49) {
      throw const FormatException(
        'olcrtc `traffic.max-payload-size` must be zero or at least 49.',
      );
    }
  }

  void _validateTransportOptions(
    String transport,
    Map<String, dynamic> options,
  ) {
    final required = switch (transport) {
      'vp8channel' => const {'fps', 'batch-size'},
      'seichannel' => const {
          'fps',
          'batch-size',
          'fragment-size',
          'ack-timeout',
        },
      'videochannel' => const {'width', 'height', 'fps', 'bitrate'},
      _ => const <String>{},
    };
    final missing = required.where((key) => !options.containsKey(key));
    if (missing.isNotEmpty) {
      throw FormatException(
        'olcrtc transport `$transport` requires: ${missing.join(', ')}.',
      );
    }

    final allowed = switch (transport) {
      'vp8channel' => const {'fps', 'batch-size'},
      'seichannel' => const {
          'fps',
          'batch-size',
          'fragment-size',
          'ack-timeout',
        },
      'videochannel' => const {
          'codec',
          'width',
          'height',
          'fps',
          'bitrate',
          'fragment-size',
          'qr-recovery',
          'tile-module',
          'tile-rs',
        },
      _ => const <String>{},
    };
    final irrelevant = options.keys.where((key) => !allowed.contains(key));
    if (irrelevant.isNotEmpty) {
      throw FormatException(
        'olcrtc transport `$transport` does not support: '
        '${irrelevant.join(', ')}.',
      );
    }
    if (transport == 'seichannel') {
      parsePublicConfigDuration(
        options['ack-timeout'],
        path: 'olcrtc.transport-options.ack-timeout',
        fallback: const Duration(seconds: 2),
        maximum: const Duration(days: 1),
      );
    }
    if (transport != 'videochannel') return;

    _requiredString(
      options['bitrate'],
      'olcrtc.transport-options.bitrate',
    );
    final codec = _string(options['codec']) ?? 'qrcode';
    if (codec == 'tile') {
      if (options.containsKey('fragment-size') ||
          options.containsKey('qr-recovery')) {
        throw const FormatException(
          'olcrtc tile codec does not support QR transport options.',
        );
      }
      final width = options['width'] ?? 1080;
      final height = options['height'] ?? 1080;
      if (width != 1080 || height != 1080) {
        throw const FormatException(
          'olcrtc tile codec requires width and height of 1080.',
        );
      }
    } else if (options.containsKey('tile-module') ||
        options.containsKey('tile-rs')) {
      throw const FormatException(
        'olcrtc qrcode codec does not support tile transport options.',
      );
    }
  }

  String _requiredString(Object? value, String path) {
    final result = _string(value);
    if (result == null) throw FormatException('$path must be non-empty.');
    return result;
  }

  String? _string(Object? value) =>
      value is String && value.isNotEmpty && value == value.trim()
          ? value
          : null;

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};

  bool _isHostPort(String value) {
    final uri = Uri.tryParse('udp://$value');
    return uri != null &&
        uri.host.isNotEmpty &&
        uri.hasPort &&
        uri.port >= 1 &&
        uri.port <= 65535 &&
        uri.userInfo.isEmpty &&
        uri.path.isEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty;
  }
}
