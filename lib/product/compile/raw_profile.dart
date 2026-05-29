import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flutter/foundation.dart';

@immutable
class RawProfile {
  const RawProfile({
    required this.profile,
    required this.config,
    required this.groupDescriptions,
    required this.providerHints,
  });

  factory RawProfile.fromConfig({
    required Profile profile,
    required Map<String, dynamic> config,
  }) =>
      RawProfile(
        profile: profile,
        config: config,
        groupDescriptions: _parseGroupDescriptions(config["proxy-groups"]),
        providerHints: ProviderAdvisoryHints(
          network: ProviderNetworkHints(
            ipv6: _asBool(config["ipv6"]),
            allowLan: _asBool(config["allow-lan"]),
            mixedPort: _asInt(config["mixed-port"]),
            findProcessMode: _parseFindProcessMode(config["find-process-mode"]),
            tunStack: _parseTunStack(config["tun"]),
          ),
          runtime: ProviderRuntimeHints(
            tcpConcurrent: _asBool(config["tcp-concurrent"]),
            unifiedDelay: _asBool(config["unified-delay"]),
            logLevel: _trimmedString(config["log-level"]),
            keepAliveInterval: _asInt(config["keep-alive-interval"]),
          ),
          externalController:
              _trimmedString(config["external-controller"]) ?? "",
        ),
      );

  final Profile profile;
  final Map<String, dynamic> config;
  final Map<String, String> groupDescriptions;
  final ProviderAdvisoryHints providerHints;

  static Map<String, String> _parseGroupDescriptions(Object? groups) {
    final descriptions = <String, String>{};
    if (groups is! List) {
      return descriptions;
    }
    for (final group in groups) {
      if (group is! Map) {
        continue;
      }
      final name = group["name"];
      final description = group["description"];
      if (name is! String || description is! String) {
        continue;
      }
      final normalizedDescription = description.trim();
      if (normalizedDescription.isEmpty) {
        continue;
      }
      descriptions[name] = normalizedDescription;
    }
    return descriptions;
  }

  static int? _asInt(Object? value) => switch (value) {
        num() => value.toInt(),
        _ => null,
      };

  static bool? _asBool(Object? value) => switch (value) {
        bool() => value,
        _ => null,
      };

  static String? _trimmedString(Object? value) {
    if (value is! String) {
      return null;
    }
    final normalizedValue = value.trim();
    return normalizedValue.isEmpty ? null : normalizedValue;
  }

  static FindProcessMode? _parseFindProcessMode(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final item in FindProcessMode.values) {
      if (item.name.toLowerCase() == value.toLowerCase()) {
        return item;
      }
    }
    return null;
  }

  static TunStack? _parseTunStack(Object? value) {
    if (value is! Map) {
      return null;
    }
    final stackValue = value["stack"];
    if (stackValue is! String) {
      return null;
    }
    for (final item in TunStack.values) {
      if (item.name.toLowerCase() == stackValue.toLowerCase()) {
        return item;
      }
    }
    return null;
  }
}

@immutable
class ProviderAdvisoryHints {
  const ProviderAdvisoryHints({
    this.network = const ProviderNetworkHints(),
    this.runtime = const ProviderRuntimeHints(),
    this.externalController = "",
  });

  final ProviderNetworkHints network;
  final ProviderRuntimeHints runtime;
  final String externalController;
}

@immutable
class ProviderNetworkHints {
  const ProviderNetworkHints({
    this.ipv6,
    this.allowLan,
    this.mixedPort,
    this.findProcessMode,
    this.tunStack,
  });

  final bool? ipv6;
  final bool? allowLan;
  final int? mixedPort;
  final FindProcessMode? findProcessMode;
  final TunStack? tunStack;
}

@immutable
class ProviderRuntimeHints {
  const ProviderRuntimeHints({
    this.tcpConcurrent,
    this.unifiedDelay,
    this.logLevel,
    this.keepAliveInterval,
  });

  final bool? tcpConcurrent;
  final bool? unifiedDelay;
  final String? logLevel;
  final int? keepAliveInterval;
}
