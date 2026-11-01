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
}
