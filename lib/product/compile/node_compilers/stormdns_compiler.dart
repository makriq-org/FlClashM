part of '../built_in_proxy_compiler.dart';

extension StormDnsNodeCompiler on BuiltInProxyCompiler {
  BuiltInProxyNodePlan _buildStormDnsPlan({
    required BuiltInProxyNodeDefinition definition,
    required BuiltInProxyDescriptor descriptor,
    required String nodeId,
    required int listenPort,
    required bool udp,
    required ConnectivityCheckConfig connectivityCheck,
    required NodeActivationConfig activation,
    required Map<Uri, StormDnsRemoteResolverList> remoteLists,
  }) {
    final rawConfig = copyConfigTree(definition.rawConfig)
      ..remove('name')
      ..remove('type')
      ..remove('udp')
      ..remove('connectivity-check')
      ..remove('activation');
    final nodeLabel = 'stormdns node `${definition.name}`';

    final sources = stormDnsResolverParser.parse(
      rawConfig.remove('resolvers'),
      label: '$nodeLabel `resolvers`',
    );
    final settings = stormDnsConfigValidator.validateEffective(
      rawConfig,
      node: nodeLabel,
    );

    final resolverLines = buildResolverFileLines(
      sources: sources,
      remoteLists: remoteLists,
    );
    if (resolverLines.isEmpty) {
      throw FormatException(
        '$nodeLabel resolved an empty resolver list. Add a reachable entry to '
        '`resolvers`, or keep `system` so the physical network DNS is used.',
      );
    }

    final fingerprint = stormDnsCacheFingerprint(
      resolverLines: resolverLines,
      domains: settings.domains,
    );
    final cacheDirectory = '$stormDnsCacheDirectoryName/$fingerprint';
    final config = buildStormDnsToml(
      settings: settings,
      listenHost: localhost,
      listenPort: listenPort,
      logDirectory: '$cacheDirectory/$stormDnsLogDirectoryName',
    );

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
        'built-in-proxies/stormdns/$nodeId/$stormDnsConfigFileName': config,
        'built-in-proxies/stormdns/$nodeId/'
                '$stormDnsResolversTemplateFileName':
            '${resolverLines.join('\n')}\n',
      },
      metadata: {
        'cache-fingerprint': fingerprint,
        'cache-directory': cacheDirectory,
        'depends-on-system-dns':
            '${resolverLines.contains(stormDnsSystemDnsPlaceholder)}',
      },
    );
  }

  /// Remote resolver-list addresses declared across every StormDNS node, with
  /// the shortest refresh window that applies to each of them.
  ///
  /// The caller resolves these before compiling, since fetching is async and
  /// compilation is not.
}
