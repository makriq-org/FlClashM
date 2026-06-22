import 'package:flutter/foundation.dart';

enum RuntimeId {
  mihomo,
  olcrtc,
  naiveproxy,
  byedpi,
}

extension RuntimeIdLabel on RuntimeId {
  String get label => switch (this) {
        RuntimeId.mihomo => 'mihomo',
        RuntimeId.olcrtc => 'olcrtc',
        RuntimeId.naiveproxy => 'naiveproxy',
        RuntimeId.byedpi => 'byedpi',
      };
}

enum RuntimeRole {
  engine,
  helper,
}

enum RuntimeCapability {
  tun,
  localSocks5Listener,
  vpnProtect,
  coldStartPersistence,
  pendingBinarySwap,
  externalServerDependency,
  transparentProxy,
}

enum RuntimeAvailabilityStatus {
  supported,
  unsupported,
}

@immutable
class RuntimeSelection {
  const RuntimeSelection({
    required this.engine,
    this.helpers = const [],
  });

  const RuntimeSelection.mihomo()
      : engine = RuntimeId.mihomo,
        helpers = const [];

  final RuntimeId engine;
  final List<RuntimeId> helpers;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RuntimeSelection &&
          runtimeType == other.runtimeType &&
          engine == other.engine &&
          listEquals(helpers, other.helpers);

  @override
  int get hashCode => Object.hash(engine, Object.hashAll(helpers));
}

@immutable
class RuntimeDescriptor {
  const RuntimeDescriptor({
    required this.id,
    required this.role,
    required this.capabilities,
  });

  final RuntimeId id;
  final RuntimeRole role;
  final Set<RuntimeCapability> capabilities;
}

@immutable
class RuntimeAvailability {
  const RuntimeAvailability.supported({
    required this.updatePath,
    required this.rollbackPath,
    this.reason = '',
  }) : status = RuntimeAvailabilityStatus.supported;

  const RuntimeAvailability.unsupported({
    required this.reason,
    required this.updatePath,
    required this.rollbackPath,
  }) : status = RuntimeAvailabilityStatus.unsupported;

  final RuntimeAvailabilityStatus status;
  final String reason;
  final String updatePath;
  final String rollbackPath;

  bool get isSupported => status == RuntimeAvailabilityStatus.supported;
}

class UnsupportedRuntimeSelectionException implements Exception {
  const UnsupportedRuntimeSelectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
