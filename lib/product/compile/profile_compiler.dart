import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/security/android_security_policy.dart';
import 'package:flutter/foundation.dart';

import 'raw_profile.dart';
import 'runtime_plan.dart';

typedef ProviderAssetPathResolver =
    Future<String> Function(String profileId, String type, String url);

@immutable
class ProfileCompileContext {
  const ProfileCompileContext({
    required this.patchConfig,
    required this.overrideNetworkSettings,
    required this.overrideDns,
    required this.routeMode,
    required this.isAndroid,
    required this.hasCurrentScript,
  });

  final ClashConfig patchConfig;
  final bool overrideNetworkSettings;
  final bool overrideDns;
  final RouteMode routeMode;
  final bool isAndroid;
  final bool hasCurrentScript;
}

class ProfileCompiler {
  const ProfileCompiler({
    this.securityPolicy = androidSecurityPolicy,
  });

  final AndroidSecurityPolicy securityPolicy;

  ResolvedProfilePatch resolvePatchConfig({
    required RawProfile? rawProfile,
    required ProfileCompileContext context,
  }) {
    var patchConfig = context.patchConfig;
    CompiledProfileMetadata? metadata;

    if (rawProfile != null) {
      if (!context.overrideNetworkSettings) {
        final providerSettings = rawProfile.providerNetworkSettings;
        patchConfig = patchConfig
            .copyWith(
              ipv6: providerSettings.ipv6 ?? patchConfig.ipv6,
              allowLan: providerSettings.allowLan ?? patchConfig.allowLan,
              mixedPort: providerSettings.mixedPort ?? patchConfig.mixedPort,
              findProcessMode:
                  providerSettings.findProcessMode ?? patchConfig.findProcessMode,
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

    if (context.isAndroid) {
      patchConfig = securityPolicy.applyToPatchConfig(patchConfig);
    }

    return ResolvedProfilePatch(
      patchConfig: patchConfig,
      metadata: metadata,
    );
  }

  Future<RuntimePlan> buildRuntimePlan({
    required RawProfile? rawProfile,
    required ProfileCompileContext context,
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

    final rawConfig = _cloneConfig(rawProfile.config);
    final patchConfig = context.patchConfig.copyWith(
      tun: context.patchConfig.tun.getRealTun(context.routeMode),
    );
    final metadata = _buildMetadata(
      rawProfile: rawProfile,
      patchConfig: context.patchConfig,
      overrideNetworkSettings: context.overrideNetworkSettings,
    );

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
      isAndroid: context.isAndroid,
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
      metadata: metadata,
    );
  }

  CompiledProfileMetadata _buildMetadata({
    required RawProfile rawProfile,
    required ClashConfig patchConfig,
    required bool overrideNetworkSettings,
  }) {
    final runtimeHints = rawProfile.runtimeHints;
    return CompiledProfileMetadata(
      externalController: rawProfile.providerExternalController.isNotEmpty
          ? rawProfile.providerExternalController
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

    if (overrideNetworkSettings) {
      rawConfig["find-process-mode"] = patchConfig.findProcessMode.name;
      rawConfig["allow-lan"] = patchConfig.allowLan;
      rawConfig["ipv6"] = patchConfig.ipv6;
      rawConfig["mixed-port"] = patchConfig.mixedPort;
    } else {
      rawConfig["find-process-mode"] ??= patchConfig.findProcessMode.name;
      rawConfig["allow-lan"] ??= patchConfig.allowLan;
      rawConfig["ipv6"] ??= patchConfig.ipv6;
      rawConfig["mixed-port"] ??= patchConfig.mixedPort;
    }

    rawConfig["geodata-loader"] = patchConfig.geodataLoader.name;
    rawConfig["global-ua"] = patchConfig.globalUa;
  }

  void _applyTunSettings({
    required Map<String, dynamic> rawConfig,
    required ClashConfig patchConfig,
    required bool overrideNetworkSettings,
    required bool isAndroid,
  }) {
    rawConfig["tun"] ??= <String, dynamic>{};
    if (isAndroid) {
      securityPolicy.applyToRawConfig(
        rawConfig,
        patchConfig: patchConfig,
      );
      return;
    }

    rawConfig["tun"]["enable"] = patchConfig.tun.enable;
    rawConfig["tun"]["device"] = patchConfig.tun.device;
    rawConfig["tun"]["dns-hijack"] = patchConfig.tun.dnsHijack;
    if (overrideNetworkSettings) {
      rawConfig["tun"]["stack"] = patchConfig.tun.stack.name;
    } else {
      rawConfig["tun"]["stack"] ??= patchConfig.tun.stack.name;
    }
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
