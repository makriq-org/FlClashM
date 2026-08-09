import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String appPlugin;

  setUpAll(() async {
    appPlugin = await File(
      'android/app/src/main/kotlin/com/follow/clashx/plugins/AppPlugin.kt',
    ).readAsString();
  });

  test('installed-package channel methods share the vendor permission gate',
      () {
    for (final method in const ['getPackages', 'getInstalledPackageNames']) {
      final handlerStart = appPlugin.indexOf('"$method" -> {');
      final handlerEnd = appPlugin.indexOf('\n            }', handlerStart);

      expect(handlerStart, greaterThanOrEqualTo(0), reason: method);
      expect(handlerEnd, greaterThan(handlerStart), reason: method);
      expect(
        appPlugin.substring(handlerStart, handlerEnd),
        contains('withInstalledAppsPermission {'),
        reason: method,
      );
    }
  });
}
