import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/clash_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new constructor options survive catalog JSON round trip', () {
    const original = CustomProxy(
      id: 1,
      definition: {
        'name': 'node',
        'type': 'vmess',
        'network': 'ws',
        'ws-opts': {
          'headers': {'Host': 'example.org'},
        },
      },
      emptyOptions: {
        ProxyField.wsMaxEarlyData,
        ProxyField.httpHeaders,
        ProxyField.h2Host,
        ProxyField.mkcpSeed,
        ProxyField.pluginTls,
      },
    );
    final restored = CustomProxy.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored, original);
  });

  test('renaming a header preserves its unedited value list', () {
    const original = CustomProxy(
      id: 1,
      definition: {
        'name': 'node',
        'type': 'vmess',
        'network': 'http',
        'http-opts': {
          'headers': {
            'X-Host': ['a.example', 'b.example'],
            'Host': ['owned.example'],
            'User-Agent': ['agent-a', 'agent-b'],
          },
        },
      },
    );
    final shown = original.stringMapOf(ProxyField.httpHeaders);
    final renamed = original.withEntries(
      ProxyField.httpHeaders,
      {'X-New': shown['X-Host']!, 'User-Agent': shown['User-Agent']!},
      originalKeys: {'X-New': 'X-Host'},
    );
    expect(renamed.valueOf(ProxyField.httpHeaders), {
      'Host': ['owned.example'],
      'X-New': ['a.example', 'b.example'],
      'User-Agent': ['agent-a', 'agent-b'],
    });
    final restored = CustomProxy.fromJson(
      jsonDecode(jsonEncode(renamed.toJson())) as Map<String, dynamic>,
    );
    expect(
      restored.valueOf(ProxyField.httpHeaders),
      renamed.valueOf(ProxyField.httpHeaders),
    );

    final edited = original.withEntries(
      ProxyField.httpHeaders,
      {'X-New': 'new.example'},
      originalKeys: {'X-New': 'X-Host'},
    );
    expect(edited.valueOf(ProxyField.httpHeaders), {
      'Host': ['owned.example'],
      'X-New': ['new.example'],
    });
  });

  for (final (network, headers, host, hostValue) in [
    (
      'http',
      ProxyField.httpHeaders,
      ProxyField.httpHost,
      ['a.example', 'b.example'],
    ),
    ('ws', ProxyField.wsHeaders, ProxyField.wsHost, 'ws.example'),
  ]) {
    test('removing $network header entries preserves the separate Host', () {
      final original = CustomProxy(
        id: 1,
        definition: {
          'name': 'node',
          'type': 'vmess',
          'network': network,
          '$network-opts': {
            'headers': {'hOsT': hostValue, 'X-Custom': 'remove-me'},
          },
        },
      );
      final cleared = original.withEntries(headers, {});
      expect(cleared.valueOf(host), hostValue);
      expect(cleared.stringMapOf(headers), isEmpty);
      final restored = CustomProxy.fromJson(
        jsonDecode(jsonEncode(cleared.toJson())) as Map<String, dynamic>,
      );
      expect(restored.valueOf(headers), {'hOsT': hostValue});
      final noHost = original.withField(host, null).withEntries(headers, {});
      expect(noHost.valueOf(headers), isNull);
    });
  }
}
