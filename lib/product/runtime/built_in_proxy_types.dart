import 'package:flutter/foundation.dart';

import 'connectivity_check.dart';

enum BuiltInProxyType { naiveproxy, byedpi, olcrtc, stormdns }

extension BuiltInProxyTypeLabel on BuiltInProxyType {
  String get label => switch (this) {
        BuiltInProxyType.naiveproxy => 'naiveproxy',
        BuiltInProxyType.byedpi => 'byedpi',
        BuiltInProxyType.olcrtc => 'olcrtc',
        BuiltInProxyType.stormdns => 'stormdns',
      };

  static BuiltInProxyType? tryParse(String? value) {
    final normalizedValue = value?.trim().toLowerCase();
    if (normalizedValue == null || normalizedValue.isEmpty) {
      return null;
    }
    for (final item in BuiltInProxyType.values) {
      if (item.label == normalizedValue) {
        return item;
      }
    }
    return null;
  }
}

enum BuiltInProxyProtocol { socks5, http }

extension BuiltInProxyProtocolLabel on BuiltInProxyProtocol {
  String get label => switch (this) {
        BuiltInProxyProtocol.socks5 => 'socks5',
        BuiltInProxyProtocol.http => 'http',
      };
}

enum NodeActivationMode { auto, always }

extension NodeActivationModeLabel on NodeActivationMode {
  String get label => switch (this) {
        NodeActivationMode.auto => 'auto',
        NodeActivationMode.always => 'always',
      };
}

@immutable
class NodeActivationConfig {
  const NodeActivationConfig({
    this.mode = NodeActivationMode.auto,
    this.wakeUrls = const [],
    this.wakeInterval = const Duration(seconds: 30),
    this.wakeFailures = 2,
    this.wakeRetryAfter = const Duration(seconds: 300),
    this.sleepIdle = const Duration(seconds: 900),
    this.watchGroup = '',
    this.containingGroups = const [],
  });

  final NodeActivationMode mode;
  final List<Uri> wakeUrls;
  final Duration wakeInterval;
  final int wakeFailures;
  final Duration wakeRetryAfter;
  final Duration sleepIdle;
  final String watchGroup;
  final List<String> containingGroups;

  bool get isAuto => mode == NodeActivationMode.auto;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.label,
        'wake': <String, dynamic>{
          'urls': wakeUrls.map((url) => url.toString()).toList(growable: false),
          'interval': wakeInterval.inSeconds,
          'failures': wakeFailures,
          'retry-after': wakeRetryAfter.inSeconds,
        },
        'sleep': <String, dynamic>{'idle': sleepIdle.inSeconds},
        'watch-group': watchGroup,
        'containing-groups': containingGroups,
      };
}

enum BuiltInProxyAvailabilityStatus { supported, unsupported }

@immutable
class BuiltInProxyAvailability {
  const BuiltInProxyAvailability.supported({
    required this.updatePath,
    required this.rollbackPath,
    this.reason = '',
  }) : status = BuiltInProxyAvailabilityStatus.supported;

  const BuiltInProxyAvailability.unsupported({
    required this.reason,
    required this.updatePath,
    required this.rollbackPath,
  }) : status = BuiltInProxyAvailabilityStatus.unsupported;

  final BuiltInProxyAvailabilityStatus status;
  final String reason;
  final String updatePath;
  final String rollbackPath;

  bool get isSupported => status == BuiltInProxyAvailabilityStatus.supported;
}

@immutable
class BuiltInProxyDescriptor {
  const BuiltInProxyDescriptor({
    required this.type,
    required this.protocol,
    required this.supportsUdp,
    required this.supportsActivation,
    required this.defaultUdp,
    required this.listenPortRangeStart,
    required this.listenPortRangeSize,
    required this.availability,
  });

  final BuiltInProxyType type;
  final BuiltInProxyProtocol protocol;
  final bool supportsUdp;
  final bool supportsActivation;
  final bool defaultUdp;
  final int listenPortRangeStart;
  final int listenPortRangeSize;
  final BuiltInProxyAvailability availability;
}

@immutable
class BuiltInProxyNodeDefinition {
  const BuiltInProxyNodeDefinition({
    required this.name,
    required this.type,
    required this.rawConfig,
  });

  final String name;
  final BuiltInProxyType type;
  final Map<String, dynamic> rawConfig;
}

@immutable
class BuiltInProxyNodePlan {
  const BuiltInProxyNodePlan({
    required this.nodeId,
    required this.name,
    required this.type,
    required this.listenHost,
    required this.listenPort,
    required this.protocol,
    required this.udp,
    this.connectivityCheck = const ConnectivityCheckConfig(),
    this.activation,
    this.files = const {},
    this.metadata = const {},
  });

  final String nodeId;
  final String name;
  final BuiltInProxyType type;
  final String listenHost;
  final int listenPort;
  final BuiltInProxyProtocol protocol;
  final bool udp;
  final ConnectivityCheckConfig connectivityCheck;
  final NodeActivationConfig? activation;
  final Map<String, String> files;

  /// Node-type specific values the controller needs at launch time but that
  /// are not artifacts, such as the StormDNS working-cache fingerprint.
  final Map<String, String> metadata;

  Map<String, dynamic> toProxyConfig() => <String, dynamic>{
        'name': name,
        'type': protocol.label,
        'server': listenHost,
        'port': listenPort,
        'udp': udp,
      };
}

class UnsupportedBuiltInProxyException implements Exception {
  const UnsupportedBuiltInProxyException(this.message);

  final String message;

  @override
  String toString() => message;
}
