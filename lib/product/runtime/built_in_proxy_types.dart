import 'package:flutter/foundation.dart';

enum BuiltInProxyType { naiveproxy, byedpi, olcrtc }

extension BuiltInProxyTypeLabel on BuiltInProxyType {
  String get label => switch (this) {
    BuiltInProxyType.naiveproxy => 'naiveproxy',
    BuiltInProxyType.byedpi => 'byedpi',
    BuiltInProxyType.olcrtc => 'olcrtc',
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
    required this.defaultUdp,
    required this.listenPortRangeStart,
    required this.listenPortRangeSize,
    required this.availability,
  });

  final BuiltInProxyType type;
  final BuiltInProxyProtocol protocol;
  final bool supportsUdp;
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
    this.files = const {},
  });

  final String nodeId;
  final String name;
  final BuiltInProxyType type;
  final String listenHost;
  final int listenPort;
  final BuiltInProxyProtocol protocol;
  final bool udp;
  final Map<String, String> files;

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
