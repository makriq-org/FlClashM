import '../runtime/built_in_proxy_types.dart';
import 'built_in_proxy_schema.dart';
import 'stormdns_config.dart';
import 'stormdns_resolver_sources.dart';
import 'strict_config_schema_validator.dart';

/// Validates the StormDNS block of a profile node.
///
/// StormDNS silently clamps most out-of-range values, so anything the upstream
/// loader would rewrite is rejected here instead. That keeps the running tunnel
/// identical to what the profile declares.
class StormDnsConfigValidator {
  const StormDnsConfigValidator({
    this.schemaValidator = const StrictConfigSchemaValidator(),
    this.settingsResolver = const StormDnsSettingsResolver(),
    this.resolverParser = const StormDnsResolverSourceParser(),
  });

  final StrictConfigSchemaValidator schemaValidator;
  final StormDnsSettingsResolver settingsResolver;
  final StormDnsResolverSourceParser resolverParser;

  /// Shape check against the declared schema: unknown, forbidden, missing, or
  /// out-of-range fields fail before anything else runs.
  void validateBuiltInNode(Map<String, dynamic> config) {
    schemaValidator.validate(
      config,
      schema: builtInProxySchemas[BuiltInProxyType.stormdns]!,
    );
  }

  /// Cross-field checks on the effective values, after the preset is applied.
  ///
  /// Returns the resolved settings so the compiler does not repeat the work.
  StormDnsSettings validateEffective(
    Map<String, dynamic> config, {
    required String node,
  }) {
    resolverParser.parse(config['resolvers'], label: '$node `resolvers`');
    return settingsResolver.resolve(config, node: node);
  }
}
