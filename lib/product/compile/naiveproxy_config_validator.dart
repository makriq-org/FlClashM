import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'strict_config_schema_validator.dart';

class NaiveProxyConfigValidator {
  const NaiveProxyConfigValidator({
    this.schemaValidator = const StrictConfigSchemaValidator(),
  });

  final StrictConfigSchemaValidator schemaValidator;

  void validate(Map<String, dynamic> config) {
    schemaValidator.validate(
      config,
      schema: builtInProxySchemas[BuiltInProxyType.naiveproxy]!,
    );
    final rawProxy = config['proxy'];
    final proxies = rawProxy is String
        ? <String>[rawProxy]
        : (rawProxy as List).cast<String>();
    if (proxies.isEmpty) {
      throw const FormatException(
          'naiveproxy.proxy must not be an empty list.');
    }
    for (var index = 0; index < proxies.length; index++) {
      final proxy = proxies[index];
      final path =
          rawProxy is String ? 'naiveproxy.proxy' : 'naiveproxy.proxy[$index]';
      if (proxy.isEmpty || proxy != proxy.trim()) {
        throw FormatException(
          '$path must be a non-empty string without surrounding whitespace.',
        );
      }
      _validateProxyChain(proxy, path);
    }
    _validatePositiveInteger(config, 'insecure-concurrency');
    _validatePositiveInteger(config, 'tunnel-timeout');
    _validatePositiveInteger(config, 'idle-timeout');
    _validateOptionalText(config, 'extra-headers', allowCrlf: true);
    _validateOptionalText(config, 'host-resolver-rules');
    _validateResolverRange(config['resolver-range']);
  }

  void _validateProxyChain(String value, String path) {
    final parts = value.split(',');
    if (parts.any((part) => part.isEmpty)) {
      throw FormatException(
        '$path must contain a valid proxy URI or proxy chain.',
      );
    }
    var sawTcpProxy = false;
    var sawSocks = false;
    for (final part in parts) {
      final uri = Uri.tryParse(part);
      if (uri == null ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.path.isNotEmpty && uri.path != '/' ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw FormatException('$path contains invalid URI `$part`.');
      }
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
        throw FormatException('$path contains invalid port in `$part`.');
      }
      switch (uri.scheme) {
        case 'quic':
          if (sawTcpProxy) {
            throw FormatException(
              '$path cannot place a QUIC proxy after a TCP proxy.',
            );
          }
          break;
        case 'http':
        case 'https':
          sawTcpProxy = true;
          break;
        case 'socks':
          sawTcpProxy = true;
          sawSocks = true;
          if (uri.userInfo.isNotEmpty) {
            throw FormatException(
              '$path does not support authenticated SOCKS proxies.',
            );
          }
          break;
        default:
          throw FormatException(
              '$path uses unsupported scheme `${uri.scheme}`.');
      }
    }
    if (sawSocks && parts.length > 1) {
      throw FormatException('$path does not support SOCKS proxies in a chain.');
    }
  }

  void _validateOptionalText(
    Map<String, dynamic> config,
    String field, {
    bool allowCrlf = false,
  }) {
    final value = config[field];
    if (value == null) return;
    final text = value as String;
    if (text.isEmpty || text != text.trim()) {
      throw FormatException('naiveproxy.$field must be a non-empty string.');
    }
    for (final unit in text.codeUnits) {
      final allowedLineBreak = allowCrlf && (unit == 0x0a || unit == 0x0d);
      if (!allowedLineBreak && (unit < 0x20 || unit == 0x7f)) {
        throw FormatException(
          'naiveproxy.$field contains a forbidden control character.',
        );
      }
    }
    if (allowCrlf) {
      for (var index = 0; index < text.length; index++) {
        final unit = text.codeUnitAt(index);
        final isBareCr = unit == 0x0d &&
            (index + 1 == text.length || text.codeUnitAt(index + 1) != 0x0a);
        final isBareLf =
            unit == 0x0a && (index == 0 || text.codeUnitAt(index - 1) != 0x0d);
        if (isBareCr || isBareLf) {
          throw const FormatException(
            'naiveproxy.extra-headers must use CRLF line endings.',
          );
        }
      }
      for (final line in text.split('\r\n')) {
        final separator = line.indexOf(':');
        final name = separator < 0 ? '' : line.substring(0, separator);
        if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name)) {
          throw const FormatException(
            'naiveproxy.extra-headers must contain CRLF-separated `name: value` headers.',
          );
        }
      }
    }
  }

  void _validatePositiveInteger(Map<String, dynamic> config, String field) {
    final value = config[field];
    if (value == null || value is int) return;
    final parsed = RegExp(r'^[1-9]\d*$').hasMatch(value as String)
        ? int.tryParse(value)
        : null;
    final maximum = field == 'insecure-concurrency' ? 4 : 2147483647;
    if (parsed == null || parsed > maximum) {
      throw FormatException(
        'naiveproxy.$field must be a decimal integer in 1..$maximum.',
      );
    }
  }

  void _validateResolverRange(Object? value) {
    if (value == null) return;
    final match = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})/(\d|[12]\d|3[0-2])$')
        .firstMatch(value as String);
    if (match == null ||
        match.group(1)!.split('.').map(int.parse).any((octet) => octet > 255)) {
      throw const FormatException(
        'naiveproxy.resolver-range must be a valid IPv4 CIDR.',
      );
    }
  }
}
