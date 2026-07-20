import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'strict_config_schema_validator.dart';

class NaiveProxyConfigValidator {
  const NaiveProxyConfigValidator({
    this.schemaValidator = const StrictConfigSchemaValidator(),
  });

  final StrictConfigSchemaValidator schemaValidator;

  void validate(Map<String, dynamic> config) {
    _validateTransport(config['transport'], config.containsKey('transport'));
    _validateInsecureConcurrency(
      config['insecure-concurrency'],
      config.containsKey('insecure-concurrency'),
    );
    schemaValidator.validate(
      config,
      schema: builtInProxySchemas[BuiltInProxyType.naiveproxy]!,
    );
    _validateServer(config['server'] as String);
    _validateCredential(config['username'] as String, 'username');
    _validateCredential(config['password'] as String, 'password');
    _validateHeaders(config['headers']);
    _validateHostResolverRules(config['host-resolver-rules']);
  }

  void _validateTransport(Object? value, bool isPresent) {
    if (!isPresent) return;
    if (value != 'https' && value != 'quic') {
      throw const FormatException(
        'naiveproxy.transport must be `https` or `quic`.',
      );
    }
  }

  void _validateInsecureConcurrency(Object? value, bool isPresent) {
    if (!isPresent) return;
    if (value is! int || value < 1 || value > 4) {
      throw const FormatException(
        'naiveproxy.insecure-concurrency must be an integer from 1 to 4.',
      );
    }
  }

  void _validateServer(String value) {
    final server = value.trim();
    if (server.isEmpty) {
      throw const FormatException(
        'naiveproxy.server must be a non-empty host name or IP address.',
      );
    }
    if (server.contains(RegExp(r'[,/@?#\\\s]'))) {
      throw const FormatException(
        'naiveproxy.server must be a host name or IP address, not a URI or proxy chain.',
      );
    }
  }

  void _validateCredential(String value, String field) {
    if (value.trim().isEmpty) {
      throw FormatException('naiveproxy.$field must be a non-empty string.');
    }
  }

  void _validateHeaders(Object? value) {
    if (value == null) return;
    final headers = value as Map;
    for (final entry in headers.entries) {
      final name = entry.key;
      final headerValue = entry.value;
      if (name is! String ||
          !RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name)) {
        throw const FormatException(
          'naiveproxy.headers contains an invalid header name.',
        );
      }
      if (headerValue is! String ||
          headerValue.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
        throw FormatException(
          'naiveproxy.headers.$name must be a string without control characters.',
        );
      }
    }
  }

  void _validateHostResolverRules(Object? value) {
    if (value == null) return;
    final rules = (value as String).trim();
    if (rules.isEmpty || rules.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException(
        'naiveproxy.host-resolver-rules must be a non-empty single-line string.',
      );
    }
  }
}
