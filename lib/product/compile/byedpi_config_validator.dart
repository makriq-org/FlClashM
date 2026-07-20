import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'byedpi_cli_validator.dart';
import 'strict_config_schema_validator.dart';

class ByedpiConfigValidator {
  const ByedpiConfigValidator({
    this.schemaValidator = const StrictConfigSchemaValidator(),
    this.cliValidator = const ByedpiCliValidator(),
  });

  final StrictConfigSchemaValidator schemaValidator;
  final ByedpiCliValidator cliValidator;

  String resolveMode(Map<String, dynamic> config) {
    final value = config['mode'];
    if (value == null) {
      return config.containsKey('args') ? 'manual' : 'auto';
    }
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw const FormatException(
        'byedpi.mode must be `manual` or `auto`.',
      );
    }
    return value;
  }

  String validate(Map<String, dynamic> config) {
    final mode = resolveMode(config);
    schemaValidator.validate(
      config,
      schema: builtInProxySchemas[BuiltInProxyType.byedpi]!,
      mode: mode,
    );
    if (mode == 'manual') {
      _requireNonEmptyString(config['args'], 'byedpi.args');
      cliValidator.validate(
        config['args'] as String,
        path: 'byedpi.args',
        context: ByedpiCliContext.args,
      );
    } else {
      final strategies = config['strategies'];
      if (strategies is List) {
        for (var index = 0; index < strategies.length; index++) {
          _requireNonEmptyString(
            strategies[index],
            'byedpi.strategies[$index]',
          );
          cliValidator.validate(
            strategies[index] as String,
            path: 'byedpi.strategies[$index]',
            context: ByedpiCliContext.strategy,
          );
        }
      }
      final fallback = config['fallback-args'];
      if (fallback != null) {
        _requireNonEmptyString(fallback, 'byedpi.fallback-args');
        cliValidator.validate(
          fallback as String,
          path: 'byedpi.fallback-args',
          context: ByedpiCliContext.fallbackArgs,
        );
      }
      final strategiesPresent = strategies is List && strategies.isNotEmpty;
      if (strategiesPresent && config.containsKey('strategy-list')) {
        throw const FormatException(
          'byedpi.strategy-list cannot be combined with byedpi.strategies.',
        );
      }
      final cache = config['cache'];
      if (cache is Map) {
        final ttl = cache['ttl'] ?? 604800;
        final recheckAfter = cache['recheck-after'] ?? 86400;
        if (ttl is int && recheckAfter is int && recheckAfter > ttl) {
          throw const FormatException(
            'byedpi.cache.recheck-after must not exceed byedpi.cache.ttl.',
          );
        }
      }
    }
    return mode;
  }

  void _requireNonEmptyString(Object? value, String path) {
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw FormatException(
        '$path must be a non-empty string without surrounding whitespace.',
      );
    }
  }
}
