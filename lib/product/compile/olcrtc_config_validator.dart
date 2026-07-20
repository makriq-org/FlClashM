import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'strict_config_schema_validator.dart';

class OlcRtcConfigValidator {
  const OlcRtcConfigValidator({
    this.schemaValidator = const StrictConfigSchemaValidator(),
  });

  final StrictConfigSchemaValidator schemaValidator;

  static const supportedProviders = {
    'jitsi',
    'telemost',
    'wbstream',
    'none',
  };
  static const supportedTransports = {
    'datachannel',
    'vp8channel',
    'seichannel',
    'videochannel',
  };

  void validateBuiltInNode(Map<String, dynamic> config) {
    final rawMode = config['mode'];
    final mode = rawMode == null
        ? 'cnc'
        : rawMode is String
            ? rawMode
            : null;
    schemaValidator.validate(
      config,
      schema: builtInProxySchemas[BuiltInProxyType.olcrtc]!,
      mode: mode,
    );
  }

  void validate(Map<String, dynamic> config) {
    _validateSectionTypes(config, prefix: '');
    if (config['debug'] != null && config['debug'] is! bool) {
      throw const FormatException('olcrtc `debug` must be a boolean.');
    }
    final failover = _section(config, 'failover');
    _validateNonNegativeDuration(
      failover['retry_delay'],
      'olcrtc `failover.retry_delay`',
    );
    final maxCycles = _int(failover['max_cycles']);
    if (failover.containsKey('max_cycles') &&
        (maxCycles == null || maxCycles < 0)) {
      throw const FormatException(
        'olcrtc `failover.max_cycles` must be a non-negative integer.',
      );
    }

    final profilesValue = config['profiles'];
    if (profilesValue != null && profilesValue is! List) {
      throw const FormatException('olcrtc `profiles` must be a list.');
    }

    final profiles = profilesValue is List ? profilesValue : const [];
    if (profiles.isEmpty) {
      _validateEffectiveConfig(config, path: 'olcrtc');
      return;
    }

    for (var index = 0; index < profiles.length; index++) {
      final profile = profiles[index];
      if (profile is! Map) {
        throw FormatException('olcrtc `profiles[$index]` must be a map.');
      }
      final normalized = _stringKeyedMap(profile);
      if (normalized['name'] != null && normalized['name'] is! String) {
        throw FormatException(
            'olcrtc `profiles[$index].name` must be a string.');
      }
      _validateSectionTypes(normalized, prefix: 'profiles[$index].');
      _validateEffectiveConfig(
        _overlayProfile(config, normalized),
        path: 'olcrtc.profiles[$index]',
      );
    }
  }

  void _validateEffectiveConfig(
    Map<String, dynamic> config, {
    required String path,
  }) {
    final auth = _section(config, 'auth');
    final provider = _exactString(auth['provider']);
    if (provider == null) {
      throw FormatException('$path.auth.provider must be non-empty.');
    }
    if (!supportedProviders.contains(provider)) {
      throw FormatException(
        '$path.auth.provider has unsupported value `$provider`; supported values: '
        '${supportedProviders.join(', ')}.',
      );
    }

    if (provider != 'none' &&
        _exactString(_section(config, 'room')['id']) == null) {
      throw FormatException(
        '$path.room.id must be non-empty when $path.auth.provider is not `none`.',
      );
    }

    final crypto = _section(config, 'crypto');
    final key = _exactString(crypto['key']);
    if (key == null) {
      throw FormatException('$path.crypto.key must be non-empty.');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key)) {
      throw FormatException(
        '$path.crypto.key must contain exactly 64 hexadecimal characters.',
      );
    }

    final net = _section(config, 'net');
    final transport = _exactString(net['transport']);
    if (transport == null) {
      throw FormatException('$path.net.transport must be non-empty.');
    }
    if (!supportedTransports.contains(transport)) {
      throw FormatException(
        '$path.net.transport has unsupported value `$transport`; supported values: '
        '${supportedTransports.join(', ')}.',
      );
    }

    final dns = _exactString(net['dns']);
    if (dns == null) {
      throw FormatException(
        '$path.net.dns must use `host:port`, for example `1.1.1.1:53`.',
      );
    }
    if (!_isHostPort(dns)) {
      throw FormatException(
        '$path.net.dns has invalid value `$dns`; expected `host:port`.',
      );
    }

    if (transport == 'vp8channel') {
      _validatePositiveIntSection(
        config,
        section: 'vp8',
        fields: const ['fps', 'batch_size'],
        path: path,
      );
    } else if (transport == 'seichannel') {
      _validatePositiveIntSection(
        config,
        section: 'sei',
        fields: const [
          'fps',
          'batch_size',
          'fragment_size',
          'ack_timeout_ms',
        ],
        path: path,
      );
    } else if (transport == 'videochannel') {
      _validatePositiveIntSection(
        config,
        section: 'video',
        fields: const ['width', 'height', 'fps'],
        path: path,
      );
    }

    final video = _section(config, 'video');
    final codec = _exactString(video['codec']);
    if (transport == 'videochannel' &&
        codec != null &&
        codec != 'qrcode' &&
        codec != 'tile') {
      throw FormatException(
        '$path.video.codec has invalid value `$codec`; supported values: qrcode, tile.',
      );
    }
    if (transport == 'videochannel' && codec == 'tile') {
      final width = _int(video['width']) ?? 1080;
      final height = _int(video['height']) ?? 1080;
      if (width != 1080 || height != 1080) {
        throw FormatException(
          '$path.video.width and $path.video.height must both be 1080 for the tile codec.',
        );
      }
    }

    final liveness = _section(config, 'liveness');
    _validatePositiveDuration(
      liveness['interval'],
      '$path.liveness.interval',
    );
    _validatePositiveDuration(
      liveness['timeout'],
      '$path.liveness.timeout',
    );
    final failures = _int(liveness['failures']);
    if (liveness.containsKey('failures') &&
        (failures == null || failures < 0)) {
      throw FormatException(
        '$path.liveness.failures must be a non-negative integer.',
      );
    }

    final lifecycle = _section(config, 'lifecycle');
    _validatePositiveDuration(
      lifecycle['max_session_duration'],
      '$path.lifecycle.max_session_duration',
    );

    final traffic = _section(config, 'traffic');
    final maxPayloadSize = _int(traffic['max_payload_size']);
    if (traffic.containsKey('max_payload_size') &&
        (maxPayloadSize == null ||
            maxPayloadSize < 0 ||
            (maxPayloadSize > 0 && maxPayloadSize < 49))) {
      throw FormatException(
        '$path.traffic.max_payload_size must be zero or at least 49.',
      );
    }
    _validateNonNegativeDuration(
      traffic['min_delay'],
      '$path.traffic.min_delay',
    );
    _validateNonNegativeDuration(
      traffic['max_delay'],
      '$path.traffic.max_delay',
    );
    final minDelay = _goDurationMicroseconds(traffic['min_delay']);
    final maxDelay = _goDurationMicroseconds(traffic['max_delay']);
    if (minDelay != null &&
        maxDelay != null &&
        maxDelay > 0 &&
        maxDelay < minDelay) {
      throw FormatException(
        '$path.traffic.max_delay must not be less than $path.traffic.min_delay.',
      );
    }
  }

  void _validateSectionTypes(
    Map<String, dynamic> config, {
    required String prefix,
  }) {
    for (final section in const [
      'auth',
      'room',
      'crypto',
      'net',
      'socks',
      'engine',
      'video',
      'vp8',
      'sei',
      'liveness',
      'lifecycle',
      'traffic',
      'failover',
      'gen',
    ]) {
      final value = config[section];
      if (value != null && value is! Map) {
        throw FormatException('olcrtc `$prefix$section` must be a map.');
      }
    }
  }

  Map<String, dynamic> _overlayProfile(
    Map<String, dynamic> base,
    Map<String, dynamic> profile,
  ) {
    final result = <String, dynamic>{...base};
    for (final entry in profile.entries) {
      if (entry.value is Map && base[entry.key] is Map) {
        final baseSection = _stringKeyedMap(base[entry.key] as Map);
        final profileSection = _stringKeyedMap(entry.value as Map);
        result[entry.key] = <String, dynamic>{
          ...baseSection,
          for (final override in profileSection.entries)
            if (!_isProfileZeroValue(override.value))
              override.key: override.value,
        };
      } else if (!_isProfileZeroValue(entry.value)) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  void _validatePositiveIntSection(
    Map<String, dynamic> config, {
    required String section,
    required List<String> fields,
    required String path,
  }) {
    final values = _section(config, section);
    for (final field in fields) {
      if (!values.containsKey(field)) {
        continue;
      }
      final value = _int(values[field]);
      if (value == null || value <= 0) {
        throw FormatException(
          '$path.$section.$field must be a positive integer.',
        );
      }
    }
  }

  void _validatePositiveDuration(Object? value, String label) {
    if (value == null) {
      return;
    }
    final text = _exactString(value);
    if (text == null || !_isPositiveGoDuration(text)) {
      throw FormatException(
          '$label must be a positive duration such as `10s`, `5m`, or `2h`.');
    }
  }

  void _validateNonNegativeDuration(Object? value, String label) {
    if (value == null) {
      return;
    }
    final text = _exactString(value);
    if (text == null || !_isGoDuration(text)) {
      throw FormatException(
        '$label must be a non-negative duration such as `0s`, `5ms`, or `2s`.',
      );
    }
  }

  bool _isPositiveGoDuration(String value) {
    if (!_isGoDuration(value)) {
      return false;
    }
    final matches = RegExp(r'(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)')
        .allMatches(value)
        .toList();
    return matches.any((match) => double.parse(match.group(1)!) > 0);
  }

  bool _isGoDuration(String value) {
    final matches = RegExp(r'(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)')
        .allMatches(value)
        .toList();
    return matches.isNotEmpty &&
        matches.map((match) => match.group(0)).join() == value;
  }

  double? _goDurationMicroseconds(Object? value) {
    if (value == null) {
      return 0;
    }
    final text = _exactString(value);
    if (text == null || !_isGoDuration(text)) {
      return null;
    }
    const factors = <String, double>{
      'ns': 0.001,
      'us': 1,
      'µs': 1,
      'ms': 1000,
      's': 1000000,
      'm': 60000000,
      'h': 3600000000,
    };
    return RegExp(r'(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)')
        .allMatches(text)
        .fold<double>(
          0,
          (total, match) =>
              total + double.parse(match.group(1)!) * factors[match.group(2)]!,
        );
  }

  bool _isHostPort(String value) {
    try {
      final uri = Uri.parse('dns://$value');
      return uri.host.isNotEmpty &&
          uri.port > 0 &&
          uri.port <= 65535 &&
          uri.path.isEmpty &&
          uri.query.isEmpty &&
          uri.fragment.isEmpty;
    } on FormatException {
      return false;
    }
  }

  Map<String, dynamic> _section(Map<String, dynamic> config, String key) {
    final value = config[key];
    return value is Map ? _stringKeyedMap(value) : <String, dynamic>{};
  }

  Map<String, dynamic> _stringKeyedMap(Map value) => value.map(
        (key, mapValue) => MapEntry(key.toString(), mapValue),
      );

  String? _exactString(Object? value) {
    if (value is! String || value.isEmpty || value != value.trim()) {
      return null;
    }
    return value;
  }

  bool _isProfileZeroValue(Object? value) =>
      value == null || value == '' || value == 0;

  int? _int(Object? value) => value is int ? value : null;
}
