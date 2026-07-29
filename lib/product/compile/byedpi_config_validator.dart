import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'byedpi_cli_validator.dart';
import 'byedpi_strategy_sources.dart';
import 'public_config_duration.dart';
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
      return config.containsKey('strategy') ? 'manual' : 'auto';
    }
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw const FormatException('byedpi.mode must be `manual` or `auto`.');
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
      _validateCli(
        config['strategy'],
        'byedpi.strategy',
        ByedpiCliContext.args,
      );
      return mode;
    }

    final strategies = config['strategies'];
    ByedpiStrategySourceParser(cliValidator: cliValidator).parse(strategies);
    final test = _map(config['strategy-test']);
    parsePublicConfigDuration(
      test['timeout'],
      path: 'byedpi.strategy-test.timeout',
      fallback: const Duration(seconds: 5),
      maximum: const Duration(minutes: 1),
    );
    final selection = _map(config['strategy-selection']);
    parsePublicConfigDuration(
      selection['startup-timeout'],
      path: 'byedpi.strategy-selection.startup-timeout',
      fallback: const Duration(seconds: 15),
      maximum: const Duration(minutes: 1),
    );
    parsePublicConfigDuration(
      selection['retry-after'],
      path: 'byedpi.strategy-selection.retry-after',
      fallback: const Duration(minutes: 5),
      maximum: const Duration(days: 365),
    );
    final fallback = selection['fallback-strategy'];
    if (fallback != null) {
      _validateCli(
        fallback,
        'byedpi.strategy-selection.fallback-strategy',
        ByedpiCliContext.fallbackArgs,
      );
    }
    final cache = _map(selection['cache']);
    final ttl = parsePublicConfigDuration(
      cache['ttl'],
      path: 'byedpi.strategy-selection.cache.ttl',
      fallback: const Duration(days: 7),
      maximum: const Duration(days: 365),
    );
    final recheck = parsePublicConfigDuration(
      cache['recheck-after'],
      path: 'byedpi.strategy-selection.cache.recheck-after',
      fallback: const Duration(days: 1),
      maximum: const Duration(days: 365),
    );
    if (recheck > ttl) {
      throw const FormatException(
        'byedpi.strategy-selection.cache.recheck-after must not exceed ttl.',
      );
    }
    return mode;
  }

  void _validateCli(Object? value, String path, ByedpiCliContext context) {
    final text = _requireNonEmptyString(value, path);
    cliValidator.validate(text, path: path, context: context);
  }

  String _requireNonEmptyString(Object? value, String path) {
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw FormatException(
        '$path must be a non-empty string without surrounding whitespace.',
      );
    }
    return value;
  }

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
}
