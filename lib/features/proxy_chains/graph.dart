import 'dart:convert';

import 'package:flclashx/models/models.dart';

enum ProxyChainIssueKind {
  missingHop,
  providerHop,
  unchainableHop,
  unreadableFilter,
  repeatedHop,
  nameTaken,
}

typedef ProxyChainIssue = ({ProxyChainIssueKind kind, String name});

const _builtins = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'COMPATIBLE',
  'PASS',
  'PASS-RULE',
  'GLOBAL',
};

/// Types whose mihomo constructors ignore `dialer-proxy`.
const _unchainableTypes = {'direct', 'dns', 'reject', 'rematch'};

/// Where mihomo's `AdapterType`, which `exclude-type` matches, differs from
/// the config's own type name.
const _adapterTypes = {
  'ss': 'Shadowsocks',
  'ssr': 'ShadowsocksR',
  'select': 'Selector',
};

typedef _Resolved = ({List<String>? leaves, ProxyChainIssue? issue});

/// One profile's outbounds with group membership resolved as mihomo does. The
/// walk happens off the UI isolate when a form opens.
class ProxyChainGraph {
  ProxyChainGraph._({
    required this.proxyTypes,
    required this.groupTypes,
    required Set<String> groupNames,
    required Set<String> providers,
    required Map<String, ProxyChainIssue> hopIssues,
  }) : _groupNames = groupNames,
       _providers = providers,
       _hopIssues = hopIssues;

  factory ProxyChainGraph.fromRaw(Map rawConfig) =>
      _GraphBuilder(rawConfig).build();

  final Map<String, String> proxyTypes;

  /// Visible groups, by name, with their types.
  final Map<String, String> groupTypes;
  final Set<String> _groupNames;
  final Set<String> _providers;
  final Map<String, ProxyChainIssue> _hopIssues;

  bool has(String name) =>
      proxyTypes.containsKey(name) || _groupNames.contains(name);

  bool _reserved(String name) =>
      has(name) ||
      _builtins.contains(name) ||
      _providers.contains(name) ||
      name.toUpperCase() == 'MATCH';

  bool isChainable(String name) => has(name) && !_hopIssues.containsKey(name);

  ProxyChainIssue? _hopIssueOf(ProxyChain chain) {
    final hops = chain.hops ?? const [];
    for (final hop in hops) {
      if (!has(hop)) {
        return (kind: ProxyChainIssueKind.missingHop, name: hop);
      }
    }
    if (hops.length != hops.toSet().length) {
      return (kind: ProxyChainIssueKind.repeatedHop, name: chain.name);
    }
    // The entry is only a dialer-proxy target, so a provider group or a node
    // that ignores dialer-proxy is still a valid starting point.
    for (final hop in hops.skip(1)) {
      if (_hopIssues[hop] case final ProxyChainIssue issue) {
        return issue;
      }
    }
    return null;
  }

  /// By chain id; a name goes to the first enabled chain that can take it.
  Map<int, ProxyChainIssue> issuesOf(Iterable<ProxyChain> chains) {
    final names = <String>{};
    final issues = <int, ProxyChainIssue>{};
    for (final chain in chains) {
      final hops = chain.hops ?? const [];
      if (hops.length < ProxyChain.minHops ||
          hops.length > ProxyChain.maxHops) {
        issues[chain.id] = (
          kind: ProxyChainIssueKind.missingHop,
          name: chain.name,
        );
        continue;
      }
      // A filter only matters for the groups a chain actually names; the
      // backend pins every include-all group with mihomo's own regexp2 before
      // clones exist, so an unrelated filter cannot fail the build.
      final issue =
          _hopIssueOf(chain) ??
          (_reserved(chain.name) || names.contains(chain.name)
              ? (kind: ProxyChainIssueKind.nameTaken, name: chain.name)
              : null);
      if (issue != null) {
        issues[chain.id] = issue;
      } else if (chain.enabled) {
        names.add(chain.name);
      }
    }
    return issues;
  }
}

class _GraphBuilder {
  _GraphBuilder(Map rawConfig)
    : _rawGroups = {
        for (final group in _maps(rawConfig['proxy-groups']))
          if (group['name'] case final String name) name: group,
      },
      _proxyTypes = {
        for (final proxy in _maps(rawConfig['proxies']))
          if (proxy['name'] case final String name)
            name: _string(proxy['type'])?.toLowerCase() ?? '',
      },
      _providers = {
        if (rawConfig['proxy-providers'] case final Map providers)
          ...providers.keys.whereType<String>(),
      };

  final Map<String, Map> _rawGroups;
  final Map<String, String> _proxyTypes;
  final Set<String> _providers;
  final _members = <String, List<String>>{};
  final _unreadable = <String>{};
  final _resolved = <String, _Resolved>{};
  late final _allProxies = [..._proxyTypes.keys]..sort(_compareBytes);

  bool _usesProviders(Map group) =>
      _strings(group['use']).isNotEmpty ||
      (_providers.isNotEmpty &&
          (group['include-all'] == true ||
              group['include-all-providers'] == true));

  bool _includesProxies(Map group) =>
      group['include-all'] == true || group['include-all-proxies'] == true;

  /// The inline proxies `include-all` brings in, before any exclusion.
  List<String>? _included(Map group) {
    if (!_includesProxies(group)) {
      return const [];
    }
    final filters = _patterns(group['filter']);
    if (filters == null) {
      return null;
    }
    return filters.isEmpty
        ? _allProxies
        : [
            for (final proxy in _allProxies)
              if (filters.any((filter) => filter.hasMatch(proxy))) proxy,
          ];
  }

  void _resolveMembers(String name, Map group) {
    final included = _included(group);
    final excluded = _patterns(group['exclude-filter']);
    if (included == null || excluded == null) {
      _unreadable.add(name);
      return;
    }
    final excludedTypes = {
      for (final type in (_string(group['exclude-type']) ?? '').split('|'))
        if (type.trim().isNotEmpty) type.trim().toLowerCase(),
    };
    _members[name] = [
      for (final member in [..._strings(group['proxies']), ...included])
        if (!excluded.any((filter) => filter.hasMatch(member)) &&
            !excludedTypes.contains(_adapterTypeOf(member)))
          member,
    ];
  }

  String _adapterTypeOf(String name) {
    final type = _proxyTypes[name] ?? _string(_rawGroups[name]?['type']) ?? '';
    return (_adapterTypes[type] ?? type).replaceAll('-', '').toLowerCase();
  }

  _Resolved _resolve(String name, Set<String> visiting) {
    if (_proxyTypes.containsKey(name)) {
      return (leaves: [name], issue: null);
    }
    final cached = _resolved[name];
    if (cached != null) {
      return cached;
    }
    final group = _rawGroups[name];
    if (group == null) {
      return (leaves: const [], issue: null);
    }
    if (!visiting.add(name)) {
      return (leaves: const [], issue: null);
    }
    final _Resolved resolved;
    if (_usesProviders(group)) {
      resolved = (
        leaves: null,
        issue: (kind: ProxyChainIssueKind.providerHop, name: name),
      );
    } else if (_unreadable.contains(name)) {
      resolved = (
        leaves: null,
        issue: (kind: ProxyChainIssueKind.unreadableFilter, name: name),
      );
    } else {
      resolved = _resolveLeaves(_members[name]!, visiting);
    }
    visiting.remove(name);
    return _resolved[name] = resolved;
  }

  _Resolved _resolveLeaves(List<String> members, Set<String> visiting) {
    final found = <String>{};
    for (final member in members) {
      final resolved = _resolve(member, visiting);
      final leaves = resolved.leaves;
      if (leaves == null) {
        return resolved;
      }
      found.addAll(leaves);
    }
    return (leaves: found.toList(), issue: null);
  }

  ProxyChainGraph build() {
    for (final MapEntry(key: name, value: group) in _rawGroups.entries) {
      _resolveMembers(name, group);
    }
    final hopIssues = <String, ProxyChainIssue>{};
    for (final name in _rawGroups.keys) {
      final resolved = _resolve(name, <String>{});
      final groupLeaves = resolved.leaves;
      if (groupLeaves == null) {
        hopIssues[name] = resolved.issue!;
        continue;
      }
      if (groupLeaves.isEmpty || groupLeaves.any(_unchainable)) {
        hopIssues[name] = (
          kind: ProxyChainIssueKind.unchainableHop,
          name: name,
        );
      }
    }
    for (final name in _proxyTypes.keys) {
      if (_unchainable(name)) {
        hopIssues[name] = (
          kind: ProxyChainIssueKind.unchainableHop,
          name: name,
        );
      }
    }
    return ProxyChainGraph._(
      proxyTypes: _proxyTypes,
      groupTypes: {
        for (final MapEntry(:key, :value) in _rawGroups.entries)
          if (value['hidden'] != true) key: _string(value['type']) ?? '',
      },
      groupNames: _rawGroups.keys.toSet(),
      providers: _providers,
      hopIssues: hopIssues,
    );
  }

  bool _unchainable(String name) =>
      _unchainableTypes.contains(_proxyTypes[name]);
}

final _leadingFlags = RegExp(r'^\(\?([a-zA-Z]+)\)');

/// mihomo compiles filters with regexp2; its leading inline flags become
/// Dart options, and anything else Dart cannot read is reported as such.
List<RegExp>? _patterns(Object? value) {
  final source = _string(value);
  if (source == null) {
    return const [];
  }
  final patterns = <RegExp>[];
  for (var pattern in source.split('`')) {
    var caseSensitive = true;
    var multiLine = false;
    var dotAll = false;
    final flags = _leadingFlags.firstMatch(pattern);
    if (flags != null) {
      for (final flag in flags.group(1)!.split('')) {
        switch (flag) {
          case 'i':
            caseSensitive = false;
          case 'm':
            multiLine = true;
          case 's':
            dotAll = true;
          default:
            return null;
        }
      }
      pattern = pattern.substring(flags.end);
    }
    if (!_readsAlike(pattern)) {
      return null;
    }
    try {
      patterns.add(
        RegExp(
          pattern,
          caseSensitive: caseSensitive,
          multiLine: multiLine,
          dotAll: dotAll,
          unicode: true,
        ),
      );
    } on FormatException {
      return null;
    }
  }
  return patterns;
}

/// Escapes that mean something else in Dart than in regexp2's .NET syntax.
const _divergentEscapes = {
  'A',
  'Z',
  'z',
  'G',
  'p',
  'P',
  'e',
  'a',
  'w',
  'W',
  'b',
  'B',
  'd',
  'D',
  's',
  'S',
  'k',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
};

bool _readsAlike(String pattern) {
  var inClass = false;
  for (var i = 0; i < pattern.length; i++) {
    final char = pattern[i];
    if (char == r'\') {
      if (i + 1 < pattern.length &&
          _divergentEscapes.contains(pattern[i + 1])) {
        return false;
      }
      i++;
    } else if (char == '[' && !inClass) {
      inClass = true;
    } else if (char == ']' && inClass) {
      inClass = false;
    } else if (inClass && pattern.startsWith('-[', i)) {
      return false;
    }
  }
  return true;
}

/// Go sorts strings by their UTF-8 bytes, as mihomo orders `include-all`.
int _compareBytes(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) {
      return x[i] - y[i];
    }
  }
  return x.length - y.length;
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Iterable<Map> _maps(Object? value) =>
    value is List ? value.whereType<Map>() : const [];

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];
