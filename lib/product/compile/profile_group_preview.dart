import '../../enum/enum.dart';
import '../../models/models.dart';

List<Group> buildProfileGroupPreview(Map<String, dynamic>? rawConfig) {
  if (rawConfig == null) {
    return const [];
  }

  final proxyGroups = rawConfig['proxy-groups'];
  if (proxyGroups is! List) {
    return const [];
  }

  final proxyDescriptions = _buildProxyDescriptions(rawConfig['proxies']);
  final groupTypes = <String, String>{};
  for (final item in proxyGroups) {
    if (item is! Map) {
      continue;
    }
    final name = item['name']?.toString().trim();
    final type = item['type']?.toString().trim();
    if (name == null || name.isEmpty || type == null || type.isEmpty) {
      continue;
    }
    final groupType = _parseGroupType(type);
    if (groupType != null) {
      groupTypes[name] = groupType.value;
    }
  }

  final groups = <Group>[];
  for (final item in proxyGroups) {
    if (item is! Map) {
      continue;
    }
    final name = item['name']?.toString().trim();
    final type = item['type']?.toString().trim();
    if (name == null || name.isEmpty || type == null || type.isEmpty) {
      continue;
    }

    final groupType = _parseGroupType(type);
    if (groupType == null) {
      continue;
    }

    final proxies = _asStringList(item['proxies'])
        .map(
          (proxyName) => Proxy(
            name: proxyName,
            type: groupTypes[proxyName] ??
                proxyDescriptions[proxyName]?.type ??
                proxyName,
            serverDescription: proxyDescriptions[proxyName]?.description,
          ),
        )
        .toList(growable: false);

    groups.add(
      Group(
        name: name,
        type: groupType,
        all: proxies,
        now: _firstNonEmpty(
          item['now']?.toString(),
          proxies.isEmpty ? null : proxies.first.name,
        ),
        hidden: item['hidden'] == true,
        testUrl: item['url']?.toString(),
        icon: item['icon']?.toString() ?? '',
      ),
    );
  }
  return groups;
}

Map<String, _ProxyDescription> _buildProxyDescriptions(dynamic rawProxies) {
  if (rawProxies is! List) {
    return const {};
  }
  final descriptions = <String, _ProxyDescription>{};
  for (final item in rawProxies) {
    if (item is! Map) {
      continue;
    }
    final name = item['name']?.toString().trim();
    final type = item['type']?.toString().trim();
    if (name == null || name.isEmpty || type == null || type.isEmpty) {
      continue;
    }
    descriptions[name] = _ProxyDescription(
      type: type,
      description: item['server']?.toString(),
    );
  }
  return descriptions;
}

GroupType? _parseGroupType(String value) {
  try {
    return GroupType.parseProfileType(value);
  } catch (_) {
    return null;
  }
}

List<String> _asStringList(dynamic value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final item in value)
      if (item.toString().trim().isNotEmpty) item.toString().trim(),
  ];
}

String? _firstNonEmpty(String? first, String? second) {
  final normalizedFirst = first?.trim();
  if (normalizedFirst != null && normalizedFirst.isNotEmpty) {
    return normalizedFirst;
  }
  final normalizedSecond = second?.trim();
  if (normalizedSecond != null && normalizedSecond.isNotEmpty) {
    return normalizedSecond;
  }
  return null;
}

class _ProxyDescription {
  const _ProxyDescription({
    required this.type,
    this.description,
  });

  final String type;
  final String? description;
}
