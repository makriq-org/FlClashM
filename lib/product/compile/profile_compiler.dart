import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';

import '../runtime/runtime_types.dart';
import '../security/product_security.dart';
import 'built_in_proxy_compiler.dart';
import 'profile_split_tunneling.dart';
import 'raw_profile.dart';
import 'runtime_plan.dart';

typedef ProviderAssetPathResolver = Future<String> Function(
    String profileId, String type, String url);

@immutable
class ProfilePatchContext {
  const ProfilePatchContext({
    required this.patchConfig,
    required this.overrideNetworkSettings,
  });

  final ClashConfig patchConfig;
  final bool overrideNetworkSettings;
}

@immutable
class RuntimePlanBuildContext {
  const RuntimePlanBuildContext({
    required this.isAndroid,
    required this.overrideNetworkSettings,
    required this.overrideDns,
    required this.routeMode,
    required this.hasCurrentScript,
    required this.profilesPath,
    required this.profilePath,
    required this.readInstalledPackageNames,
  });

  final bool isAndroid;
  final bool overrideNetworkSettings;
  final bool overrideDns;
  final RouteMode routeMode;
  final bool hasCurrentScript;
  final String profilesPath;
  final String profilePath;
  final Future<List<String>> Function() readInstalledPackageNames;
}

class ProfileCompiler {
  const ProfileCompiler({
    this.builtInProxyCompiler = const BuiltInProxyCompiler(),
  });

  final BuiltInProxyCompiler builtInProxyCompiler;

  CompiledProfilePatch compileProfilePatch({
    required RawProfile? rawProfile,
    required ProfilePatchContext context,
  }) {
    var patchConfig = context.patchConfig;
    CompiledProfileMetadata? metadata;

    if (rawProfile != null) {
      if (!context.overrideNetworkSettings) {
        final providerSettings = rawProfile.providerHints.network;
        patchConfig = patchConfig
            .copyWith(
              ipv6: providerSettings.ipv6 ?? patchConfig.ipv6,
              allowLan: providerSettings.allowLan ?? patchConfig.allowLan,
              mixedPort: providerSettings.mixedPort ?? patchConfig.mixedPort,
              findProcessMode: providerSettings.findProcessMode ??
                  patchConfig.findProcessMode,
            )
            .copyWith
            .tun(stack: providerSettings.tunStack ?? patchConfig.tun.stack);
      }
      metadata = _buildMetadata(
        rawProfile: rawProfile,
        patchConfig: patchConfig,
        overrideNetworkSettings: context.overrideNetworkSettings,
      );
    }

    return CompiledProfilePatch(
      patchConfig: patchConfig,
      metadata: metadata,
    );
  }

  Future<RuntimePlan> buildRuntimePlan({
    required RawProfile? rawProfile,
    required RuntimePlanBuildContext context,
    required SecuredProfilePatch securedProfile,
    required ClashConfig runtimePatchConfig,
    required Map<String, String> selectedMap,
    required String testUrl,
    required ProviderAssetPathResolver providerAssetPathResolver,
  }) async {
    if (rawProfile == null) {
      return RuntimePlan.empty(
        selectedMap: selectedMap,
        testUrl: testUrl,
      );
    }

    var rawConfig = _cloneConfig(rawProfile.config);
    final patchConfig = runtimePatchConfig.copyWith(
      tun: runtimePatchConfig.tun.getRealTun(context.routeMode),
    );
    final metadata = securedProfile.metadata ??
        _buildMetadata(
          rawProfile: rawProfile,
          patchConfig: runtimePatchConfig,
          overrideNetworkSettings: context.overrideNetworkSettings,
        );
    final resolvedProfileSplitTunneling =
        await _resolveProfileSplitTunnelingOverride(
      rawConfig: rawConfig,
      rawProfile: rawProfile,
      context: context,
    );
    final compiledBuiltInProxyNodes = builtInProxyCompiler.compile(
      rawConfig: resolvedProfileSplitTunneling.config,
      patchConfig: patchConfig,
    );
    rawConfig = compiledBuiltInProxyNodes.config;

    _applyCoreRuntimeSettings(
      rawConfig: rawConfig,
      patchConfig: patchConfig,
      metadata: metadata,
      overrideNetworkSettings: context.overrideNetworkSettings,
    );
    _applyTunSettings(
      rawConfig: rawConfig,
      patchConfig: patchConfig,
      overrideNetworkSettings: context.overrideNetworkSettings,
      runtimeConstraints: securedProfile.runtimeConstraints,
    );
    _normalizeSnifferPorts(rawConfig);
    await _rewriteProviderPaths(
      rawConfig: rawConfig,
      profileId: rawProfile.profile.id,
      providerAssetPathResolver: providerAssetPathResolver,
    );
    _mergeGeoXUrl(rawConfig: rawConfig, patchConfig: patchConfig);
    _mergeHosts(rawConfig: rawConfig, patchConfig: patchConfig);
    _mergeDns(
      rawConfig: rawConfig,
      patchConfig: patchConfig,
      overrideDns: context.overrideDns,
    );
    _mergeRules(
      rawConfig: rawConfig,
      profile: rawProfile.profile,
      hasCurrentScript: context.hasCurrentScript,
    );

    return RuntimePlan(
      config: rawConfig,
      selectedMap: selectedMap,
      testUrl: testUrl,
      runtime: const RuntimeSelection.mihomo(),
      files: {
        for (final node in compiledBuiltInProxyNodes.nodes) ...node.files,
      },
      builtInProxyNodes: compiledBuiltInProxyNodes.nodes,
      metadata: metadata,
      profileAccessControl: resolvedProfileSplitTunneling.accessControl,
    );
  }

  Future<ResolvedProfileSplitTunneling> _resolveProfileSplitTunnelingOverride({
    required Map<String, dynamic> rawConfig,
    required RawProfile rawProfile,
    required RuntimePlanBuildContext context,
  }) async {
    if (!context.isAndroid) {
      return ResolvedProfileSplitTunneling(
        config: rawConfig,
        accessControl: null,
      );
    }

    final installedPackageNames =
        requiresInstalledPackageInventoryForProfileSplitTunneling(
      rawConfig,
      isAndroid: context.isAndroid,
    )
            ? await context.readInstalledPackageNames()
            : const <String>[];
    return resolveAndroidProfileSplitTunneling(
      rawConfig: rawConfig,
      isAndroid: context.isAndroid,
      profilesPath: context.profilesPath,
      profileId: rawProfile.profile.id,
      installedPackageNames: installedPackageNames,
    );
  }

  CompiledProfileMetadata _buildMetadata({
    required RawProfile rawProfile,
    required ClashConfig patchConfig,
    required bool overrideNetworkSettings,
  }) {
    final providerHints = rawProfile.providerHints;
    final runtimeHints = providerHints.runtime;
    return CompiledProfileMetadata(
      externalController: !overrideNetworkSettings &&
              providerHints.externalController.isNotEmpty
          ? providerHints.externalController
          : patchConfig.externalController.value,
      tcpConcurrent: overrideNetworkSettings
          ? patchConfig.tcpConcurrent
          : (runtimeHints.tcpConcurrent ?? patchConfig.tcpConcurrent),
      unifiedDelay: overrideNetworkSettings
          ? patchConfig.unifiedDelay
          : (runtimeHints.unifiedDelay ?? patchConfig.unifiedDelay),
      logLevel: overrideNetworkSettings
          ? patchConfig.logLevel.name
          : (runtimeHints.logLevel ?? patchConfig.logLevel.name),
      keepAliveInterval: overrideNetworkSettings
          ? patchConfig.keepAliveInterval
          : (runtimeHints.keepAliveInterval ?? patchConfig.keepAliveInterval),
      groupDescriptions: rawProfile.groupDescriptions,
    );
  }

  Map<String, dynamic> _cloneConfig(Map<String, dynamic> rawConfig) {
    final encoded = json.encode(rawConfig);
    return Map<String, dynamic>.from(json.decode(encoded) as Map);
  }

  void _applyCoreRuntimeSettings({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
    required CompiledProfileMetadata metadata,
    required bool overrideNetworkSettings,
  }) {
    rawConfig["external-controller"] = metadata.externalController;
    if (rawConfig["external-ui"] == null || rawConfig["external-ui"] == "") {
      rawConfig["external-ui"] = "";
    }
    rawConfig["interface-name"] = "";
    if (rawConfig["external-ui-url"] == null ||
        rawConfig["external-ui-url"] == "") {
      rawConfig["external-ui-url"] = "";
    }

    rawConfig["tcp-concurrent"] = metadata.tcpConcurrent;
    rawConfig["unified-delay"] = metadata.unifiedDelay;
    rawConfig["log-level"] = metadata.logLevel;
    rawConfig["keep-alive-interval"] = metadata.keepAliveInterval;
    rawConfig["port"] = patchConfig.port;
    rawConfig["socks-port"] = patchConfig.socksPort;
    rawConfig["redir-port"] = patchConfig.redirPort;
    rawConfig["tproxy-port"] = patchConfig.tproxyPort;
    rawConfig["mode"] = patchConfig.mode.name;
    rawConfig["find-process-mode"] = patchConfig.findProcessMode.name;
    rawConfig["allow-lan"] = patchConfig.allowLan;
    rawConfig["ipv6"] = patchConfig.ipv6;
    rawConfig["mixed-port"] = patchConfig.mixedPort;

    rawConfig["geodata-loader"] = patchConfig.geodataLoader.name;
    rawConfig["global-ua"] = patchConfig.globalUa;
  }

  void _applyTunSettings({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
    required bool overrideNetworkSettings,
    required RuntimeSecurityConstraints runtimeConstraints,
  }) {
    rawConfig["tun"] ??= <String, dynamic>{};
    if (runtimeConstraints.enforceTun) {
      rawConfig["tun"]["enable"] = true;
      rawConfig["tun"]["device"] = patchConfig.tun.device;
      rawConfig["tun"]["dns-hijack"] = patchConfig.tun.dnsHijack;
      rawConfig["tun"]["stack"] = patchConfig.tun.stack.name;
      rawConfig["tun"]["route-address"] = patchConfig.tun.routeAddress;
      rawConfig["tun"]["auto-route"] = patchConfig.tun.autoRoute;
      return;
    }

    rawConfig["tun"]["enable"] = patchConfig.tun.enable;
    rawConfig["tun"]["device"] = patchConfig.tun.device;
    rawConfig["tun"]["dns-hijack"] = patchConfig.tun.dnsHijack;
    rawConfig["tun"]["stack"] = patchConfig.tun.stack.name;
    rawConfig["tun"]["route-address"] = patchConfig.tun.routeAddress;
    rawConfig["tun"]["auto-route"] = patchConfig.tun.autoRoute;
  }

  void _normalizeSnifferPorts(Map<String, dynamic> rawConfig) {
    final sniffers = rawConfig["sniffer"]?["sniff"];
    if (sniffers is! Map) {
      return;
    }
    for (final value in sniffers.values) {
      if (value is! Map) {
        continue;
      }
      final ports = value["ports"];
      if (ports is! List) {
        continue;
      }
      value["ports"] = ports.map((item) => item.toString()).toList();
    }
  }

  Future<void> _rewriteProviderPaths({
    required Map<String, dynamic> rawConfig,
    required String profileId,
    required ProviderAssetPathResolver providerAssetPathResolver,
  }) async {
    final proxyProviders = rawConfig["proxy-providers"];
    if (proxyProviders is Map) {
      for (final entry in proxyProviders.entries) {
        final provider = entry.value;
        if (provider is! Map || provider["type"] != "http") {
          continue;
        }
        final url = provider["url"];
        if (url is! String) {
          continue;
        }
        provider["path"] = await providerAssetPathResolver(
          profileId,
          "proxies",
          url,
        );
      }
    }

    final ruleProviders = rawConfig["rule-providers"];
    if (ruleProviders is Map) {
      for (final entry in ruleProviders.entries) {
        final provider = entry.value;
        if (provider is! Map || provider["type"] != "http") {
          continue;
        }
        final url = provider["url"];
        if (url is! String) {
          continue;
        }
        provider["path"] = await providerAssetPathResolver(
          profileId,
          "rules",
          url,
        );
      }
    }
  }

  void _mergeGeoXUrl({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
  }) {
    rawConfig["profile"] ??= <String, dynamic>{};
    rawConfig["profile"]["store-selected"] = false;

    final mergedGeoXUrl = <String, dynamic>{};
    final patchGeoX = patchConfig.geoXUrl.toJson();
    final profileGeoX = rawConfig["geox-url"];

    mergedGeoXUrl["geoip"] = patchGeoX["geoip"];
    mergedGeoXUrl["mmdb"] = patchGeoX["mmdb"];
    mergedGeoXUrl["asn"] = patchGeoX["asn"];
    mergedGeoXUrl["geosite"] = patchGeoX["geosite"];

    if (profileGeoX is Map) {
      if (profileGeoX["geoip"] != null) {
        mergedGeoXUrl["geoip"] = profileGeoX["geoip"];
      }
      if (profileGeoX["mmdb"] != null) {
        mergedGeoXUrl["mmdb"] = profileGeoX["mmdb"];
      }
      if (profileGeoX["asn"] != null) {
        mergedGeoXUrl["asn"] = profileGeoX["asn"];
      }
      if (profileGeoX["geosite"] != null) {
        mergedGeoXUrl["geosite"] = profileGeoX["geosite"];
      }
    }

    rawConfig["geox-url"] = mergedGeoXUrl;
  }

  void _mergeHosts({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
  }) {
    rawConfig["hosts"] ??= <String, dynamic>{};
    for (final host in patchConfig.hosts.entries) {
      rawConfig["hosts"][host.key] = host.value.splitByMultipleSeparators;
    }
  }

  void _mergeDns({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
    required bool overrideDns,
  }) {
    rawConfig["dns"] ??= <String, dynamic>{};
    final isEnableDns = rawConfig["dns"]["enable"] == true;
    if (!overrideDns && isEnableDns) {
      return;
    }

    final dns = !isEnableDns
        ? patchConfig.dns.copyWith(
            nameserver: [...patchConfig.dns.nameserver, "system://"],
          )
        : patchConfig.dns;
    rawConfig["dns"] = dns.toJson();
    rawConfig["dns"]["nameserver-policy"] = <String, dynamic>{};
    for (final entry in dns.nameserverPolicy.entries) {
      rawConfig["dns"]["nameserver-policy"][entry.key] =
          entry.value.splitByMultipleSeparators;
    }
  }

  void _mergeRules({
    required Map<String, dynamic> rawConfig,
    required Profile profile,
    required bool hasCurrentScript,
  }) {
    var rules = <dynamic>[];
    final currentRules = rawConfig["rules"];
    if (currentRules is List) {
      rules = [...currentRules];
    }
    rawConfig.remove("rules");

    final overrideData = profile.overrideData;
    if (overrideData.enable && !hasCurrentScript) {
      if (overrideData.rule.type == OverrideRuleType.override) {
        rules = [...overrideData.runningRule];
      } else {
        rules = [...overrideData.runningRule, ...rules];
      }
    }

    rawConfig["rule"] = rules;
  }
}
