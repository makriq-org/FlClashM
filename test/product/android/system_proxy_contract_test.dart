import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android VPN publishes the mixed port as a system proxy on API 29+', () {
    final source = File(
      'android/service/src/main/kotlin/com/follow/clashx/service/'
      'FlVpnService.kt',
    ).readAsStringSync();

    expect(
      source,
      contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q'),
    );
    expect(source, contains('options.systemProxy'));
    expect(source, contains('options.port in 1..65535'));
    expect(source, contains('builder.setHttpProxy('));
    expect(source, contains('ProxyInfo.buildDirectProxy('));
    expect(source, contains('"127.0.0.1"'));
    expect(source, contains('options.bypassDomain'));
  });
}
