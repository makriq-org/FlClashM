import 'package:flclashx/features/proxy_chains/graph.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _config() => {
  'proxies': <Map<String, Object?>>[
    {'name': 'DE', 'type': 'vless', 'server': 'de.example'},
    {'name': 'NL', 'type': 'trojan', 'server': 'nl.example'},
    {'name': 'Direct', 'type': 'direct'},
  ],
  'proxy-providers': <String, Object?>{'remote': <String, Object?>{}},
  'proxy-groups': <Map<String, Object?>>[
    {
      'name': 'Auto',
      'type': 'url-test',
      'proxies': ['DE', 'NL'],
      'url': 'https://example.test',
    },
    {
      'name': 'Remote',
      'type': 'select',
      'use': ['remote'],
    },
    {
      'name': 'Mixed',
      'type': 'select',
      'proxies': ['DE', 'Direct'],
    },
    {
      'name': 'All',
      'type': 'select',
      'include-all': true,
      'proxies': ['Auto'],
    },
  ],
};

ProxyChain _chain(
  int id,
  String name,
  List<String> hops, {
  bool enabled = true,
}) {
  return ProxyChain(id: id, name: name, hops: hops, enabled: enabled);
}

void main() {
  test('the entry may be a provider group, later hops must be chainable', () {
    final graph = ProxyChainGraph.fromRaw(_config());
    expect(graph.isChainable('Auto'), isTrue);
    expect(graph.isChainable('Remote'), isFalse);
    expect(graph.isChainable('Mixed'), isFalse);
    expect(graph.isChainable('Direct'), isFalse);

    final issues = graph.issuesOf([
      _chain(1, 'FromProvider', ['Remote', 'NL']),
      _chain(2, 'ThroughDirect', ['Auto', 'Direct']),
    ]);
    expect(issues[1], isNull);
    expect(issues[2]?.kind, ProxyChainIssueKind.unchainableHop);
  });

  test('missing, repeated and taken declarations are reported', () {
    final graph = ProxyChainGraph.fromRaw(_config());
    final issues = graph.issuesOf([
      _chain(1, 'Missing', ['Auto', 'Ghost']),
      _chain(2, 'Twice', ['Auto', 'NL', 'NL']),
      _chain(3, 'Auto', ['DE', 'NL']),
    ]);
    expect(issues[1]?.kind, ProxyChainIssueKind.missingHop);
    expect(issues[2]?.kind, ProxyChainIssueKind.repeatedHop);
    expect(issues[3]?.kind, ProxyChainIssueKind.nameTaken);
  });

  test('a filter Dart cannot read is reported before the chain is saved', () {
    final graph = ProxyChainGraph.fromRaw({
      'proxies': [
        {'name': 'DE', 'type': 'vless'},
        {'name': 'NL', 'type': 'trojan'},
      ],
      'proxy-groups': [
        {
          'name': 'Auto',
          'type': 'select',
          'proxies': ['DE'],
        },
        {
          'name': 'Filtered',
          'type': 'select',
          'include-all-proxies': true,
          'filter': r'\p{L}',
        },
      ],
    });
    expect(
      graph.issuesOf([
        _chain(1, 'Sharp', ['Auto', 'Filtered']),
      ])[1]?.kind,
      ProxyChainIssueKind.unreadableFilter,
    );
  });

  test('a disabled chain does not take its name', () {
    final graph = ProxyChainGraph.fromRaw(_config());
    final issues = graph.issuesOf([
      _chain(1, 'Off', ['Auto', 'NL'], enabled: false),
      _chain(2, 'Off', ['DE', 'NL']),
    ]);
    expect(issues, isEmpty);
  });
}
