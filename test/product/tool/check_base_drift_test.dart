import 'package:flutter_test/flutter_test.dart';

import '../../../tool/check_base_drift.dart';

void main() {
  group('BaseDriftAllowlist.fromJson', () {
    test('parses manifest entries', () {
      final allowlist = BaseDriftAllowlist.fromJson({
        'allowedBaseDrift': [
          {
            'path': r'lib\views\dashboard.dart',
            'reason': 'Reason',
            'bucket': 'incapsulate-pending',
          },
        ],
      });

      expect(allowlist.entries, hasLength(1));
      expect(allowlist.entries.single.path, 'lib/views/dashboard.dart');
      expect(allowlist.entries.single.bucket, 'incapsulate-pending');
    });
  });

  group('scanBaseDrift', () {
    test('reports changed files outside allowlist', () {
      final failures = <String>[];
      final result = scanBaseDrift(
        BaseDriftAllowlist.fromJson({
          'allowedBaseDrift': [
            {
              'path': 'lib/controller.dart',
              'reason': 'Intentional runtime drift.',
              'bucket': 'budget',
            },
          ],
        }),
        changedPaths: const [
          'lib/controller.dart',
          'lib/views/theme.dart',
        ],
        failures: failures,
      );

      expect(result.allowlistedCount, 1);
      expect(result.outsideAllowlistCount, 1);
      expect(result.bucketCounts['budget'], 1);
      expect(failures, hasLength(1));
      expect(
        failures.single,
        contains('lib/views/theme.dart'),
      );
    });
  });
}
