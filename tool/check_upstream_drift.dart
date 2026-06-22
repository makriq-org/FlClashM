import 'dart:convert';
import 'dart:io';

const inventoryPath = 'tool/product_touchpoints.json';
const upstreamRef = 'upstream/dev';

void main(List<String> args) {
  final result = checkUpstreamDrift(args);
  if (result != 0) exit(result);
}

int checkUpstreamDrift(List<String> args) {
  if (!args.contains('--skip-fetch')) {
    final fetch = Process.runSync('git', ['fetch', 'upstream', 'dev']);
    if (fetch.exitCode != 0) {
      stderr.writeln('Could not fetch upstream/dev: ${fetch.stderr}');
      return 1;
    }
  }

  if (Process.runSync('git', ['rev-parse', '--verify', upstreamRef]).exitCode !=
      0) {
    stderr.writeln('Could not resolve $upstreamRef.');
    return 1;
  }

  final inventory = _readInventory();
  if (inventory == null) return 1;

  final changedFiles = _listChangedFiles();
  final failures = <String>[];
  for (final path in changedFiles) {
    if (!isAllowedUpstreamChange(
      path,
      allowedFiles: inventory.allowedFiles,
      productOwnedRoots: inventory.productOwnedRoots,
    )) {
      failures.add(
        'Drift outside product/touchpoints: `$path`. Restore it from '
        '$upstreamRef or declare an explicit, documented touchpoint in '
        '$inventoryPath.',
      );
    }
  }

  final staleFiles = inventory.allowedFiles.difference(changedFiles.toSet());
  for (final path in staleFiles) {
    failures.add(
      'Stale touchpoint `$path`: it no longer differs from $upstreamRef. '
      'Remove it from $inventoryPath.',
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Upstream drift guard failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    stderr.writeln('Total: ${failures.length} failure(s).');
    return 1;
  }

  stdout
    ..writeln('Upstream drift guard passed.')
    ..writeln(
      'Changed files: ${changedFiles.length}; explicit touchpoints: '
      '${inventory.allowedFiles.length}; product-owned roots: '
      '${inventory.productOwnedRoots.length}; unauthorized drift: 0.',
    );
  return 0;
}

bool isAllowedUpstreamChange(
  String path, {
  required Set<String> allowedFiles,
  required List<String> productOwnedRoots,
}) =>
    allowedFiles.contains(path) || productOwnedRoots.any(path.startsWith);

List<String> _listChangedFiles() {
  final result = Process.runSync('git', ['diff', '--name-only', upstreamRef]);
  if (result.exitCode != 0) {
    throw StateError('git diff $upstreamRef failed: ${result.stderr}');
  }

  final files = <String>{
    for (final line in (result.stdout as String).split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  };
  final untracked =
      Process.runSync('git', ['ls-files', '--others', '--exclude-standard']);
  if (untracked.exitCode != 0) {
    throw StateError('git ls-files failed: ${untracked.stderr}');
  }
  for (final line in (untracked.stdout as String).split('\n')) {
    if (line.trim().isNotEmpty) files.add(line.trim());
  }
  return files.toList()..sort();
}

_TouchpointInventory? _readInventory() {
  final file = File(inventoryPath);
  if (!file.existsSync()) {
    stderr.writeln('Missing touchpoint inventory `$inventoryPath`.');
    return null;
  }

  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('Invalid touchpoint inventory format.');
    return null;
  }

  final allowedFiles = <String>{};
  for (final section in const [
    'allowedProductImports',
    'allowedBaseExtensions',
    'allowedIdentityFiles',
    'allowedGeneratedFiles',
  ]) {
    final entries = decoded[section];
    if (entries is! List) {
      stderr.writeln('Missing inventory section `$section`.');
      return null;
    }
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> || entry['path'] is! String) {
        stderr.writeln('Invalid entry in `$section`.');
        return null;
      }
      if (!allowedFiles.add(entry['path'] as String)) {
        stderr.writeln('Duplicate touchpoint `${entry['path']}`.');
        return null;
      }
    }
  }

  final roots = <String>[];
  final rootEntries = decoded['productOwnedRoots'];
  if (rootEntries is! List || rootEntries.isEmpty) {
    stderr.writeln('Missing `productOwnedRoots`.');
    return null;
  }
  for (final entry in rootEntries) {
    if (!_hasContract(entry) || !(entry['path'] as String).endsWith('/')) {
      stderr.writeln('Invalid product-owned root entry.');
      return null;
    }
    roots.add(entry['path'] as String);
  }

  final groups = decoded['allowedFileGroups'];
  if (groups is! List || groups.isEmpty) {
    stderr.writeln('Missing `allowedFileGroups`.');
    return null;
  }
  for (final group in groups) {
    if (!_hasContract(group) || group['paths'] is! List) {
      stderr.writeln('Invalid allowed file group.');
      return null;
    }
    for (final path in (group['paths'] as List)) {
      if (path is! String || path.isEmpty || !allowedFiles.add(path)) {
        stderr.writeln('Invalid or duplicate grouped touchpoint `$path`.');
        return null;
      }
    }
  }

  return _TouchpointInventory(
    allowedFiles: allowedFiles,
    productOwnedRoots: roots,
  );
}

bool _hasContract(Object? value) {
  if (value is! Map<String, dynamic>) return false;
  for (final key in const [
    'path',
    'boundary',
    'reason',
    'contract',
    'security',
    'rollback',
  ]) {
    if (key == 'path' && value['paths'] is List) continue;
    final field = value[key];
    if (field is! String || field.trim().isEmpty) return false;
  }
  return true;
}

class _TouchpointInventory {
  const _TouchpointInventory({
    required this.allowedFiles,
    required this.productOwnedRoots,
  });

  final Set<String> allowedFiles;
  final List<String> productOwnedRoots;
}
