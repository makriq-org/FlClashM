import 'package:flutter_test/flutter_test.dart';

import '../../../tool/check_product_boundaries.dart';

void main() {
  group('collectProductImports', () {
    test('normalizes package and relative product imports to canonical targets',
        () {
      final imports = collectProductImports(
        '''
import '../product/platform/platform_profile.dart';
export 'package:flclashx/product/services/product_services.dart';
import 'package:external_pkg/product/runtime.dart';
''',
        sourcePath: 'lib/providers/state.dart',
        packageName: 'flclashx',
      );

      expect(imports, <String>{
        'lib/product/platform/platform_profile.dart',
        'lib/product/services/product_services.dart',
      });
    });
  });

  group('ProductTouchpoint.fromJson', () {
    test('accepts canonical targets inventory entries', () {
      final touchpoint = ProductTouchpoint.fromJson(
        {
          'path': 'lib/main.dart',
          'boundary': 'bootstrap-entrypoint',
          'reason': 'Main may bootstrap into product layer.',
          'targets': ['lib/product/bootstrap/app_bootstrap.dart'],
        },
        packageName: 'flclashx',
      );

      expect(touchpoint.targets, ['lib/product/bootstrap/app_bootstrap.dart']);
    });
  });
}
