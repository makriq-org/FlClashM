import 'package:flutter_test/flutter_test.dart';

import '../../../tool/check_base_drift.dart';

void main() {
  group('pinned upstream import', () {
    test('requires immutable source and valid package names', () {
      expect(
        () => UpstreamImport.fromJson({
          'commit': 'upstream/dev',
          'sourcePackage': 'fl_clash',
          'localPackage': 'flclashx',
        }),
        throwsStateError,
      );
      expect(
        () => UpstreamImport.fromJson({
          'commit': 'a' * 40,
          'sourcePackage': '../lib',
          'localPackage': 'flclashx',
        }),
        throwsStateError,
      );
    });
    test('normalizes only the package import prefix', () {
      const config = UpstreamImport(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'fl_clash',
        'flclashx',
      );
      expect(
        normalizeImportedDart(
          "import 'package:fl_clash/views/theme.dart';\nconst brand='fl_clash';",
          config,
        ),
        "import 'package:flclashx/views/theme.dart';\nconst brand='fl_clash';",
      );
    });
    test('counts verified imports without allowing unrelated changes', () {
      final failures = <String>[];
      final result = scanBaseDrift(
        const BaseDriftAllowlist(entries: []),
        changedPaths: ['lib/views/theme.dart', 'lib/main.dart'],
        importedPaths: {'lib/views/theme.dart'},
        failures: failures,
      );
      expect(result.importedCount, 1);
      expect(result.allowlistedCount, 0);
      expect(result.outsideAllowlistCount, 1);
      expect(failures.single, contains('lib/main.dart'));
    });
  });
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
        changedPaths: const ['lib/controller.dart', 'lib/views/theme.dart'],
        failures: failures,
      );

      expect(result.allowlistedCount, 1);
      expect(result.outsideAllowlistCount, 1);
      expect(result.bucketCounts['budget'], 1);
      expect(failures, hasLength(1));
      expect(failures.single, contains('lib/views/theme.dart'));
    });

    test('reports uncommitted changed files outside allowlist', () {
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
          'lib/controller.dart',
          'core/runtime_patch.dart',
        ],
        failures: failures,
      );

      expect(result.allowlistedCount, 1);
      expect(result.outsideAllowlistCount, 1);
      expect(failures, hasLength(1));
      expect(failures.single, contains('core/runtime_patch.dart'));
    });
  });
}
