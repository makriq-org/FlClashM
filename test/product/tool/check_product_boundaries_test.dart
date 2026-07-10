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

  group('collectProductUiDeclarations', () {
    test('detects product pages and widget factories', () {
      final declarations = collectProductUiDeclarations('''
class SendToTvPage extends ConsumerStatefulWidget {
  const SendToTvPage();
}

Widget buildProductBadge() => const SizedBox.shrink();
      ''');

      expect(
        declarations,
        {
          'SendToTvPage extends ConsumerStatefulWidget',
          'Widget buildProductBadge(...)',
        },
      );
    });

    test('ignores Flutter use without a widget declaration', () {
      final declarations = collectProductUiDeclarations('''
import 'package:flutter/material.dart' show DynamicSchemeVariant;

void bootstrap() => WidgetsFlutterBinding.ensureInitialized();
      ''');

      expect(declarations, isEmpty);
    });
  });

  group('validateProductUiAllowances', () {
    test('rejects an unregistered product page', () {
      final failures = <String>[];

      validateProductUiAllowances(
        expectedUiByPath: const {},
        actualProductUiByPath: {
          'lib/product/pages/send_to_tv.dart': {
            'SendToTvPage extends ConsumerStatefulWidget',
          },
        },
        failures: failures,
      );

      expect(failures, hasLength(1));
      expect(failures.single, contains('Unexpected product UI'));
      expect(failures.single, contains('send_to_tv.dart'));
    });

    test('rejects a stale product UI allowance', () {
      final failures = <String>[];
      const path = 'lib/product/pages/removed_page.dart';

      validateProductUiAllowances(
        expectedUiByPath: const {
          path: ProductUiAllowance(
            path: path,
            reason: 'Product-owned page.',
          ),
        },
        actualProductUiByPath: const {},
        failures: failures,
      );

      expect(failures, hasLength(1));
      expect(failures.single, contains('stale'));
      expect(failures.single, contains(path));
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

  group('ProductTouchpointInventory.fromJson', () {
    test('parses explicit product UI allowances', () {
      final inventory = ProductTouchpointInventory.fromJson(
        {
          'allowedProductImports': <Object>[],
          'allowedProductUi': [
            {
              'path': r'lib\product\android\android_update_bridge.dart',
              'reason': 'Product updater dialog.',
            },
          ],
        },
        packageName: 'flclashx',
      );

      expect(inventory.allowedProductUi, hasLength(1));
      expect(
        inventory.allowedProductUi.single.path,
        'lib/product/android/android_update_bridge.dart',
      );
    });
  });
}
