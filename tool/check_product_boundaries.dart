import 'dart:convert';
import 'dart:io';

const inventoryPath = 'tool/product_touchpoints.json';
const pubspecPath = 'pubspec.yaml';
const libRootPath = 'lib';
const productRootPath = 'lib/product/';

void main() {
  final failures = <String>[];
  String? packageName;
  try {
    packageName = readPackageName();
  } on Object catch (error) {
    failures.add('$error');
  }

  ProductTouchpointInventory? inventory;

  if (packageName != null) {
    try {
      inventory = readInventory(packageName: packageName);
    } on Object catch (error) {
      failures.add('$error');
    }
  }

  BoundaryScanResult? result;
  if (inventory != null && packageName != null) {
    result = scanProductBoundaries(
      inventory,
      packageName: packageName,
      failures: failures,
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Product boundary guard failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout
    ..writeln('Product boundary guard passed.')
    ..writeln(
      'Allowed touchpoints: ${inventory!.allowedImports.length}, '
      'product-layer files: ${result!.productFileCount}, '
      'base touchpoints: ${result.baseTouchpointCount}, '
      'product UI files: ${result.productUiFileCount}.',
    );
}

String readPackageName() {
  final file = File(pubspecPath);
  if (!file.existsSync()) {
    throw StateError('Missing pubspec `$pubspecPath`.');
  }

  final match = RegExp(r'^\s*name:\s*([a-z0-9_]+)\s*$', multiLine: true)
      .firstMatch(file.readAsStringSync());
  if (match == null) {
    throw StateError('Could not read package name from `$pubspecPath`.');
  }
  return match.group(1)!;
}

ProductTouchpointInventory readInventory({
  required String packageName,
}) {
  final file = File(inventoryPath);
  if (!file.existsSync()) {
    throw StateError('Missing product touchpoint inventory `$inventoryPath`.');
  }

  final data = jsonDecode(file.readAsStringSync());
  if (data is! Map<String, dynamic>) {
    throw StateError('Expected `$inventoryPath` to contain a JSON object.');
  }
  return ProductTouchpointInventory.fromJson(
    data,
    packageName: packageName,
  );
}

BoundaryScanResult scanProductBoundaries(
  ProductTouchpointInventory inventory, {
  required String packageName,
  required List<String> failures,
}) {
  final expectedByPath = <String, ProductTouchpoint>{};
  for (final touchpoint in inventory.allowedImports) {
    final normalizedPath = normalizePath(touchpoint.path);
    final previous = expectedByPath[normalizedPath];
    if (previous != null) {
      failures.add(
        'Duplicate touchpoint path `$normalizedPath` in `$inventoryPath`.',
      );
      continue;
    }
    if (normalizedPath.startsWith(productRootPath)) {
      failures.add(
        'Touchpoint `$normalizedPath` must stay outside `lib/product/**`.',
      );
    }
    expectedByPath[normalizedPath] = touchpoint;
  }

  final expectedUiByPath = <String, ProductUiAllowance>{};
  for (final allowance in inventory.allowedProductUi) {
    final normalizedPath = normalizePath(allowance.path);
    if (!normalizedPath.startsWith(productRootPath)) {
      failures.add(
        'Product UI allowance `$normalizedPath` must stay under '
        '`lib/product/**`.',
      );
      continue;
    }
    if (expectedUiByPath.containsKey(normalizedPath)) {
      failures.add(
        'Duplicate product UI allowance `$normalizedPath` in '
        '`$inventoryPath`.',
      );
      continue;
    }
    expectedUiByPath[normalizedPath] = allowance;
  }

  final actualByPath = <String, Set<String>>{};
  final actualProductUiByPath = <String, Set<String>>{};
  var productFileCount = 0;

  final entities = Directory(libRootPath).listSync(recursive: true);
  for (final entity in entities) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }

    final path = normalizePath(entity.path);
    if (path.startsWith(productRootPath)) {
      productFileCount++;
      final declarations = collectProductUiDeclarations(
        entity.readAsStringSync(),
      );
      if (declarations.isNotEmpty) {
        actualProductUiByPath[path] = declarations;
      }
      continue;
    }

    final productImports = collectProductImports(
      entity.readAsStringSync(),
      sourcePath: path,
      packageName: packageName,
    );
    if (productImports.isNotEmpty) {
      actualByPath[path] = productImports;
    }
  }

  for (final entry in actualByPath.entries) {
    final touchpoint = expectedByPath[entry.key];
    if (touchpoint == null) {
      failures.add(
        'Unexpected product import outside `lib/product/**`: `${entry.key}` -> '
        '${formatSet(entry.value)}. Move logic into `lib/product/**` or add an '
        'intentional touchpoint in `$inventoryPath` with rationale.',
      );
      continue;
    }

    final expectedTargets = touchpoint.targets.toSet();
    final actualTargets = entry.value;
    final missing = expectedTargets.difference(actualTargets);
    final unexpected = actualTargets.difference(expectedTargets);
    if (missing.isNotEmpty || unexpected.isNotEmpty) {
      failures.add(
        'Touchpoint `${entry.key}` drifted. '
        'expected=${formatSet(expectedTargets)}, '
        'actual=${formatSet(actualTargets)}, '
        'missing=${formatSet(missing)}, '
        'unexpected=${formatSet(unexpected)}.',
      );
    }
  }

  for (final touchpoint in inventory.allowedImports) {
    if (!actualByPath.containsKey(touchpoint.path)) {
      failures.add(
        'Touchpoint `${touchpoint.path}` from `$inventoryPath` is stale or '
        'missing its product import. Update the inventory with the code change.',
      );
    }
  }

  validateProductUiAllowances(
    expectedUiByPath: expectedUiByPath,
    actualProductUiByPath: actualProductUiByPath,
    failures: failures,
  );

  return BoundaryScanResult(
    productFileCount: productFileCount,
    baseTouchpointCount: actualByPath.length,
    productUiFileCount: actualProductUiByPath.length,
  );
}

Set<String> collectProductUiDeclarations(String content) {
  final declarations = <String>{};
  final widgetClasses = RegExp(
    r'\bclass\s+([A-Za-z_]\w*)[^\{;]*\bextends\s+'
    r'([A-Za-z_]\w*Widget)\b',
    multiLine: true,
  );
  for (final match in widgetClasses.allMatches(content)) {
    declarations.add('${match.group(1)} extends ${match.group(2)}');
  }

  final widgetFactories = RegExp(
    r'^\s*Widget\??\s+([A-Za-z_]\w*)\s*\(',
    multiLine: true,
  );
  for (final match in widgetFactories.allMatches(content)) {
    declarations.add('Widget ${match.group(1)}(...)');
  }
  return declarations;
}

void validateProductUiAllowances({
  required Map<String, ProductUiAllowance> expectedUiByPath,
  required Map<String, Set<String>> actualProductUiByPath,
  required List<String> failures,
}) {
  for (final entry in actualProductUiByPath.entries) {
    if (!expectedUiByPath.containsKey(entry.key)) {
      failures.add(
        'Unexpected product UI in `${entry.key}`: '
        '${formatSet(entry.value)}. Keep the live upstream screen in base or '
        'add an intentional `allowedProductUi` entry in `$inventoryPath` '
        'with rationale.',
      );
    }
  }

  for (final allowance in expectedUiByPath.values) {
    if (!actualProductUiByPath.containsKey(allowance.path)) {
      failures.add(
        'Product UI allowance `${allowance.path}` from `$inventoryPath` is '
        'stale or contains no detected widget declaration.',
      );
    }
  }
}

Set<String> collectProductImports(
  String content, {
  required String sourcePath,
  required String packageName,
}) {
  final matches = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  ).allMatches(content);

  final uris = <String>{};
  for (final match in matches) {
    final uri = match.group(1);
    if (uri == null) {
      continue;
    }
    final target = resolveProductTarget(
      fromPath: sourcePath,
      reference: uri,
      packageName: packageName,
    );
    if (target == null) {
      continue;
    }
    uris.add(target);
  }
  return uris;
}

String? resolveProductTarget({
  required String fromPath,
  required String reference,
  required String packageName,
}) {
  final normalizedReference = normalizePath(reference);
  if (normalizedReference.startsWith(productRootPath)) {
    return normalizedReference;
  }

  if (normalizedReference.startsWith('package:')) {
    final match =
        RegExp(r'^package:([^/]+)/(.+)$').firstMatch(normalizedReference);
    if (match == null) {
      return null;
    }

    if (match.group(1) != packageName) {
      return null;
    }

    final packagePath = match.group(2)!;
    if (!packagePath.startsWith('product/')) {
      return null;
    }
    return '$libRootPath/$packagePath';
  }

  if (normalizedReference.contains(':')) {
    return null;
  }

  final sourceUri = Uri.parse('file:///${normalizePath(fromPath)}');
  final resolved = sourceUri.resolve(normalizedReference);
  final resolvedPath = normalizePath(
    resolved.path.startsWith('/') ? resolved.path.substring(1) : resolved.path,
  );
  if (!resolvedPath.startsWith(productRootPath)) {
    return null;
  }
  return resolvedPath;
}

String normalizePath(String path) => path.replaceAll(r'\', '/');

String formatSet(Set<String> values) {
  final sorted = values.toList()..sort();
  return sorted.isEmpty ? '[]' : '[${sorted.join(', ')}]';
}

class BoundaryScanResult {
  const BoundaryScanResult({
    required this.productFileCount,
    required this.baseTouchpointCount,
    required this.productUiFileCount,
  });

  final int productFileCount;
  final int baseTouchpointCount;
  final int productUiFileCount;
}

class ProductTouchpointInventory {
  const ProductTouchpointInventory({
    required this.allowedImports,
    required this.allowedProductUi,
  });

  factory ProductTouchpointInventory.fromJson(
    Map<String, dynamic> json, {
    required String packageName,
  }) {
    final value = json['allowedProductImports'];
    if (value is! List) {
      throw StateError(
        '`allowedProductImports` must be a list in `$inventoryPath`.',
      );
    }

    final allowedProductUiValue = json['allowedProductUi'];
    if (allowedProductUiValue is! List) {
      throw StateError(
        '`allowedProductUi` must be a list in `$inventoryPath`.',
      );
    }

    return ProductTouchpointInventory(
      allowedImports: value.map((item) {
        if (item is! Map<String, dynamic>) {
          throw StateError(
            'Each touchpoint in `$inventoryPath` must be an object.',
          );
        }
        return ProductTouchpoint.fromJson(item, packageName: packageName);
      }).toList(growable: false),
      allowedProductUi: allowedProductUiValue.map((item) {
        if (item is! Map<String, dynamic>) {
          throw StateError(
            'Each product UI allowance in `$inventoryPath` must be an object.',
          );
        }
        return ProductUiAllowance.fromJson(item);
      }).toList(growable: false),
    );
  }

  final List<ProductTouchpoint> allowedImports;
  final List<ProductUiAllowance> allowedProductUi;
}

class ProductUiAllowance {
  const ProductUiAllowance({
    required this.path,
    required this.reason,
  });

  factory ProductUiAllowance.fromJson(Map<String, dynamic> json) =>
      ProductUiAllowance(
        path: normalizePath(_readString(json, key: 'path')),
        reason: _readString(json, key: 'reason'),
      );

  final String path;
  final String reason;
}

class ProductTouchpoint {
  const ProductTouchpoint({
    required this.path,
    required this.boundary,
    required this.reason,
    required this.targets,
  });

  factory ProductTouchpoint.fromJson(
    Map<String, dynamic> json, {
    required String packageName,
  }) {
    final path = normalizePath(_readString(json, key: 'path'));
    final boundary = _readString(json, key: 'boundary');
    final reason = _readString(json, key: 'reason');
    final targets = _readProductTargets(
      json,
      path: path,
      packageName: packageName,
    );
    return ProductTouchpoint(
      path: path,
      boundary: boundary,
      reason: reason,
      targets: targets,
    );
  }

  final String path;
  final String boundary;
  final String reason;
  final List<String> targets;
}

String _readString(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw StateError('`$key` must be a non-empty string in `$inventoryPath`.');
  }
  return value;
}

List<String> _readStringList(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! List || value.isEmpty || value.any((item) => item is! String)) {
    throw StateError(
      '`$key` must be a non-empty string list in `$inventoryPath`.',
    );
  }
  return value.cast<String>();
}

List<String> _readProductTargets(
  Map<String, dynamic> json, {
  required String path,
  required String packageName,
}) {
  final targetsValue = json['targets'];
  if (targetsValue != null) {
    if (targetsValue is! List ||
        targetsValue.isEmpty ||
        targetsValue.any((item) => item is! String)) {
      throw StateError(
        '`targets` must be a non-empty string list in `$inventoryPath`.',
      );
    }
    return targetsValue
        .cast<String>()
        .map((target) => _normalizeProductTarget(target, path: path))
        .toList(growable: false);
  }

  final imports = _readStringList(json, key: 'imports');
  return imports.map((reference) {
    final target = resolveProductTarget(
      fromPath: path,
      reference: reference,
      packageName: packageName,
    );
    if (target == null) {
      throw StateError(
        'Touchpoint `$path` contains non-product import `$reference` in '
        '`$inventoryPath`.',
      );
    }
    return target;
  }).toList(growable: false);
}

String _normalizeProductTarget(
  String target, {
  required String path,
}) {
  final normalizedTarget = normalizePath(target);
  if (!normalizedTarget.startsWith(productRootPath)) {
    throw StateError(
      'Touchpoint `$path` contains non-product target `$target` in '
      '`$inventoryPath`.',
    );
  }
  return normalizedTarget;
}
