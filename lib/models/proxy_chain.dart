import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// One authored proxy chain: the device connects to the first hop, traffic
/// leaves from the last, and every later hop dials through the one before it.
@immutable
class ProxyChain {
  const ProxyChain({
    required this.id,
    required this.name,
    required this.hops,
    this.enabled = true,
    this.profileId,
    this.order,
  });

  static const minHops = 2;
  static const maxHops = 3;

  final int id;
  final String name;
  final List<String>? hops;
  final bool enabled;
  final String? profileId;
  final String? order;

  static ProxyChain? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final rawId = json['id'];
    final id = rawId is int ? rawId : int.tryParse('$rawId');
    final name = json['name'];
    final rawHops = json['hops'];
    final enabled = json['enabled'] ?? true;
    final profileId = json['profileId'];
    final order = json['order'];
    if (id == null ||
        name is! String ||
        name.trim().isEmpty ||
        enabled is! bool ||
        rawHops is! List ||
        rawHops.length < minHops ||
        rawHops.length > maxHops ||
        rawHops.any((hop) => hop is! String || hop.isEmpty) ||
        (profileId != null && profileId is! String) ||
        (order != null && order is! String)) {
      return null;
    }
    return ProxyChain(
      id: id,
      name: name,
      hops: rawHops.cast<String>().toList(),
      enabled: enabled,
      profileId: profileId as String?,
      order: order as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'hops': hops,
    'enabled': enabled,
    if (profileId != null) 'profileId': profileId,
    if (order != null) 'order': order,
  };

  ProxyChain copyWith({
    String? name,
    List<String>? hops,
    bool? enabled,
    String? profileId,
    String? order,
  }) {
    return ProxyChain(
      id: id,
      name: name ?? this.name,
      hops: hops ?? this.hops,
      enabled: enabled ?? this.enabled,
      profileId: profileId ?? this.profileId,
      order: order ?? this.order,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProxyChain &&
      other.id == id &&
      other.name == name &&
      other.enabled == enabled &&
      other.profileId == profileId &&
      other.order == order &&
      const ListEquality<String>().equals(other.hops, hops);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    enabled,
    profileId,
    order,
    Object.hashAll(hops ?? const []),
  );
}
