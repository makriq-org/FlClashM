import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/check_upstream_drift.dart';

void main() {
  final inventoryFile = File('tool/product_touchpoints.json');

  setUpAll(() {
    if (!inventoryFile.existsSync()) {
      throw StateError('Missing tool/product_touchpoints.json');
    }
  });

  test('check_upstream_drift inventory has all required sections', () {
    final data = jsonDecode(inventoryFile.readAsStringSync());
    expect(data, isA<Map<String, dynamic>>());

    expect(data['allowedProductImports'], isA<List>());
    expect((data['allowedProductImports'] as List).isNotEmpty, true);

    expect(data['allowedBaseExtensions'], isA<List>());
    expect((data['allowedBaseExtensions'] as List).isNotEmpty, true);

    expect(data['allowedIdentityFiles'], isA<List>());
    expect((data['allowedIdentityFiles'] as List).isNotEmpty, true);

    expect(data['allowedGeneratedFiles'], isA<List>());
    expect((data['allowedGeneratedFiles'] as List).isNotEmpty, true);
  });

  test('check_upstream_drift every base extension has required metadata', () {
    final data = jsonDecode(inventoryFile.readAsStringSync());
    final extensions = data['allowedBaseExtensions'] as List;

    for (final ext in extensions) {
      final map = ext as Map<String, dynamic>;
      expect(map['path'], isA<String>());
      expect((map['path'] as String).isNotEmpty, true);
      expect(map['boundary'], isA<String>());
      expect((map['boundary'] as String).isNotEmpty, true);
      expect(map['reason'], isA<String>());
      expect((map['reason'] as String).isNotEmpty, true);
      expect(map['contract'], isA<String>());
      expect((map['contract'] as String).isNotEmpty, true);
      expect(map['security'], isA<String>());
      expect((map['security'] as String).isNotEmpty, true);
      expect(map['rollback'], isA<String>());
      expect((map['rollback'] as String).isNotEmpty, true);
    }
  });

  test('check_upstream_drift no touchpoint path is inside lib/product', () {
    final data = jsonDecode(inventoryFile.readAsStringSync());
    final allPaths = <String>[
      ...(data['allowedProductImports'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
      ...(data['allowedBaseExtensions'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
      ...(data['allowedIdentityFiles'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
      ...(data['allowedGeneratedFiles'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
    ];

    for (final path in allPaths) {
      expect(
        path.startsWith('lib/product/'),
        false,
        reason: 'Touchpoint $path must be outside lib/product/**',
      );
    }
  });

  test('check_upstream_drift no duplicate paths across touchpoint sections',
      () {
    final data = jsonDecode(inventoryFile.readAsStringSync());
    final allPaths = <String>[
      ...(data['allowedProductImports'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
      ...(data['allowedBaseExtensions'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
      ...(data['allowedIdentityFiles'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
      ...(data['allowedGeneratedFiles'] as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String),
    ];

    final seen = <String>{};
    for (final path in allPaths) {
      expect(
        seen.contains(path),
        false,
        reason: 'Duplicate touchpoint path: $path',
      );
      seen.add(path);
    }
  });

  test('drift guard allows only exact files and declared product roots', () {
    const allowedFiles = {'lib/state.dart'};
    const productRoots = ['lib/product/'];

    expect(
      isAllowedUpstreamChange(
        'lib/state.dart',
        allowedFiles: allowedFiles,
        productOwnedRoots: productRoots,
      ),
      isTrue,
    );
    expect(
      isAllowedUpstreamChange(
        'lib/product/runtime/engine_manager.dart',
        allowedFiles: allowedFiles,
        productOwnedRoots: productRoots,
      ),
      isTrue,
    );
    expect(
      isAllowedUpstreamChange(
        'lib/views/dashboard/dashboard.dart',
        allowedFiles: allowedFiles,
        productOwnedRoots: productRoots,
      ),
      isFalse,
    );
    expect(
      isAllowedUpstreamChange(
        'android/service/Unexpected.kt',
        allowedFiles: allowedFiles,
        productOwnedRoots: productRoots,
      ),
      isFalse,
    );
  });
}
