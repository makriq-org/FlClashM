import 'package:flclashx/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FlClashHttpOverrides never uses a local proxy listener', () {

    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('http://127.0.0.1:9090')),
      'DIRECT',
    );
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('http://localhost:9090')),
      'DIRECT',
    );
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('http://[::1]:9090')),
      'DIRECT',
    );
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('https://example.com')),
      'DIRECT',
    );
  });

  test('FlClashHttpOverrides keeps direct traffic when runtime is inactive',
      () {
    expect(
      FlClashHttpOverrides.handleFindProxy(Uri.parse('https://example.com')),
      'DIRECT',
    );
  });

}
