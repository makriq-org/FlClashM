import 'dart:convert';
import 'dart:io';

const allowlistPath = 'tool/base_drift_allowlist.json';
const defaultUpstreamRef = 'upstream/dev';
const mergeBaseEnvKey = 'BASE_DRIFT_MERGE_BASE';
const upstreamRefEnvKey = 'BASE_DRIFT_UPSTREAM_REF';
const allowedBuckets = <String>{
  'budget',
  'rename',
  'incapsulate-pending',
  'revert-pending',
};
const trackedBasePathspecs = <String>[
  '--',
  'lib',
  'android',
  'core',
  ':(exclude)lib/product',
  ':(exclude)lib/l10n',
];

void main(List<String> args) {
  final failures = <String>[];

  BaseDriftCliConfig? config;
  try {
    config = BaseDriftCliConfig.parse(args, Platform.environment);
  } on Object catch (error) {
    failures.add('$error');
  }

  BaseDriftAllowlist? allowlist;
  try {
    allowlist = readAllowlist();
  } on Object catch (error) {
    failures.add('$error');
  }

  if (failures.isNotEmpty) {
    _printFailure(failures);
    return;
  }

  final mergeBaseLookup = resolveMergeBase(config!);
  if (mergeBaseLookup.skipReason != null) {
    stdout
      ..writeln('Base drift guard skipped.')
      ..writeln(mergeBaseLookup.skipReason)
      ..writeln('Allowlist entries: ${allowlist!.entries.length}.');
    return;
  }

  List<String> changedPaths;
  try {
    changedPaths = listChangedBaseFiles(mergeBase: mergeBaseLookup.mergeBase!);
  } on Object catch (error) {
    failures.add('$error');
    _printFailure(failures);
    return;
  }

  final result = scanBaseDrift(
    allowlist!,
    changedPaths: changedPaths,
    failures: failures,
  );

  if (failures.isNotEmpty) {
    _printFailure(
      failures,
      summary: result.summaryLine,
      bucketSummary: result.bucketSummaryLine,
    );
    return;
  }

  stdout
    ..writeln('Base drift guard passed.')
    ..writeln(result.summaryLine)
    ..writeln(result.bucketSummaryLine);
}

void _printFailure(
  List<String> failures, {
  String? summary,
  String? bucketSummary,
}) {
  stderr.writeln('Base drift guard failed:');
  for (final failure in failures) {
    stderr.writeln('- $failure');
  }
  if (summary != null) {
    stderr.writeln(summary);
  }
  if (bucketSummary != null) {
    stderr.writeln(bucketSummary);
  }
  exitCode = 1;
}

BaseDriftAllowlist readAllowlist() {
  final file = File(allowlistPath);
  if (!file.existsSync()) {
    throw StateError('Missing base drift allowlist `$allowlistPath`.');
  }

  final data = jsonDecode(file.readAsStringSync());
  if (data is! Map<String, dynamic>) {
    throw StateError('Expected `$allowlistPath` to contain a JSON object.');
  }
  return BaseDriftAllowlist.fromJson(data);
}

MergeBaseLookupResult resolveMergeBase(BaseDriftCliConfig config) {
  final mergeBase = config.mergeBase;
  if (mergeBase != null && mergeBase.isNotEmpty) {
    return MergeBaseLookupResult.found(mergeBase);
  }

  final refCheck = Process.runSync('git', [
    'rev-parse',
    '--verify',
    '--quiet',
    config.upstreamRef,
  ]);
  if (refCheck.exitCode != 0) {
    return MergeBaseLookupResult.skip(
      'Git ref `${config.upstreamRef}` is unavailable. '
      'Pass `--merge-base=<sha>` or set `$mergeBaseEnvKey` in CI.',
    );
  }

  final result =
      Process.runSync('git', ['merge-base', 'HEAD', config.upstreamRef]);
  if (result.exitCode != 0) {
    return MergeBaseLookupResult.skip(
      'Could not compute merge-base with `${config.upstreamRef}`. '
      'Pass `--merge-base=<sha>` or set `$mergeBaseEnvKey` in CI.',
    );
  }

  final resolvedMergeBase = _trimProcessOutput(result.stdout);
  if (resolvedMergeBase.isEmpty) {
    return MergeBaseLookupResult.skip(
      'Git returned an empty merge-base for `${config.upstreamRef}`. '
      'Pass `--merge-base=<sha>` or set `$mergeBaseEnvKey` in CI.',
    );
  }

  return MergeBaseLookupResult.found(resolvedMergeBase);
}

List<String> listChangedBaseFiles({
  required String mergeBase,
}) {
  final changedPaths = <String>{};

  changedPaths.addAll(_listGitPaths(
    [
      'diff',
      '--name-only',
      '$mergeBase..HEAD',
      ...trackedBasePathspecs,
    ],
    errorPrefix: 'Failed to list committed base files',
  ));
  changedPaths.addAll(_listGitPaths(
    [
      'diff',
      '--name-only',
      '--cached',
      ...trackedBasePathspecs,
    ],
    errorPrefix: 'Failed to list staged base files',
  ));
  changedPaths.addAll(_listGitPaths(
    [
      'diff',
      '--name-only',
      ...trackedBasePathspecs,
    ],
    errorPrefix: 'Failed to list unstaged base files',
  ));
  changedPaths.addAll(_listGitPaths(
    [
      'ls-files',
      '--others',
      '--exclude-standard',
      ...trackedBasePathspecs,
    ],
    errorPrefix: 'Failed to list untracked base files',
  ));

  final sortedPaths = changedPaths.toList()..sort();
  return List.unmodifiable(sortedPaths);
}

BaseDriftScanResult scanBaseDrift(
  BaseDriftAllowlist allowlist, {
  required Iterable<String> changedPaths,
  required List<String> failures,
}) {
  final allowedByPath = <String, BaseDriftEntry>{};
  for (final entry in allowlist.entries) {
    final normalizedPath = normalizePath(entry.path);
    final previous = allowedByPath[normalizedPath];
    if (previous != null) {
      failures.add(
        'Duplicate base drift path `$normalizedPath` in `$allowlistPath`.',
      );
      continue;
    }
    if (!_isTrackedBasePath(normalizedPath)) {
      failures.add(
        'Allowlist path `$normalizedPath` must stay under `lib`, `android` or '
        '`core`, outside `lib/product/**` and `lib/l10n`.',
      );
      continue;
    }
    allowedByPath[normalizedPath] = entry;
  }

  final bucketCounts = {
    for (final bucket in allowedBuckets) bucket: 0,
  };
  final unexpectedPaths = <String>[];
  final normalizedChangedPaths =
      changedPaths.map(normalizePath).toSet().toList()..sort();

  for (final path in normalizedChangedPaths) {
    if (!_isTrackedBasePath(path)) {
      continue;
    }
    final entry = allowedByPath[path];
    if (entry == null) {
      unexpectedPaths.add(path);
      continue;
    }
    bucketCounts[entry.bucket] = bucketCounts[entry.bucket]! + 1;
  }

  if (unexpectedPaths.isNotEmpty) {
    failures.add(
      'Changed base files missing from `$allowlistPath`: '
      '${unexpectedPaths.join(', ')}.',
    );
  }

  return BaseDriftScanResult(
    allowlistedCount: normalizedChangedPaths.length - unexpectedPaths.length,
    outsideAllowlistCount: unexpectedPaths.length,
    bucketCounts: bucketCounts,
  );
}

bool _isTrackedBasePath(String path) {
  if (path.startsWith('lib/product/')) {
    return false;
  }
  if (path.startsWith('lib/l10n/')) {
    return false;
  }
  return path.startsWith('lib/') ||
      path.startsWith('android/') ||
      path.startsWith('core/');
}

String normalizePath(String path) => path.replaceAll(r'\', '/');

String _trimProcessOutput(Object? value) => '$value'.trim();

List<String> _listGitPaths(
  List<String> arguments, {
  required String errorPrefix,
}) {
  final result = Process.runSync('git', arguments);
  if (result.exitCode != 0) {
    throw StateError('$errorPrefix: ${_readProcessMessage(result)}');
  }

  final output = _trimProcessOutput(result.stdout);
  if (output.isEmpty) {
    return const [];
  }

  return output
      .split('\n')
      .map(normalizePath)
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
}

String _readProcessMessage(ProcessResult result) {
  final stderrText = _trimProcessOutput(result.stderr);
  if (stderrText.isNotEmpty) {
    return stderrText;
  }
  final stdoutText = _trimProcessOutput(result.stdout);
  if (stdoutText.isNotEmpty) {
    return stdoutText;
  }
  return 'exitCode=${result.exitCode}';
}

class BaseDriftCliConfig {
  const BaseDriftCliConfig({
    required this.mergeBase,
    required this.upstreamRef,
  });

  factory BaseDriftCliConfig.parse(
    List<String> args,
    Map<String, String> environment,
  ) {
    String? mergeBase = environment[mergeBaseEnvKey];
    var upstreamRef = environment[upstreamRefEnvKey] ?? defaultUpstreamRef;

    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      if (argument.startsWith('--merge-base=')) {
        mergeBase = argument.substring('--merge-base='.length);
        continue;
      }
      if (argument == '--merge-base') {
        if (index + 1 >= args.length) {
          throw StateError('Missing value after `--merge-base`.');
        }
        mergeBase = args[++index];
        continue;
      }
      if (argument.startsWith('--upstream-ref=')) {
        upstreamRef = argument.substring('--upstream-ref='.length);
        continue;
      }
      if (argument == '--upstream-ref') {
        if (index + 1 >= args.length) {
          throw StateError('Missing value after `--upstream-ref`.');
        }
        upstreamRef = args[++index];
        continue;
      }
      throw StateError('Unknown argument `$argument`.');
    }

    return BaseDriftCliConfig(
      mergeBase: mergeBase,
      upstreamRef: upstreamRef,
    );
  }

  final String? mergeBase;
  final String upstreamRef;
}

class MergeBaseLookupResult {
  const MergeBaseLookupResult._({
    this.mergeBase,
    this.skipReason,
  });

  factory MergeBaseLookupResult.found(String mergeBase) =>
      MergeBaseLookupResult._(mergeBase: mergeBase);

  factory MergeBaseLookupResult.skip(String reason) =>
      MergeBaseLookupResult._(skipReason: reason);

  final String? mergeBase;
  final String? skipReason;
}

class BaseDriftScanResult {
  const BaseDriftScanResult({
    required this.allowlistedCount,
    required this.outsideAllowlistCount,
    required this.bucketCounts,
  });

  final int allowlistedCount;
  final int outsideAllowlistCount;
  final Map<String, int> bucketCounts;

  String get summaryLine =>
      'Changed base files: ${allowlistedCount + outsideAllowlistCount}. '
      'Allowlisted: $allowlistedCount. '
      'New outside allowlist: $outsideAllowlistCount.';

  String get bucketSummaryLine => 'Buckets: budget=${bucketCounts['budget']}, '
      'rename=${bucketCounts['rename']}, '
      'incapsulate-pending=${bucketCounts['incapsulate-pending']}, '
      'revert-pending=${bucketCounts['revert-pending']}.';
}

class BaseDriftAllowlist {
  const BaseDriftAllowlist({
    required this.entries,
  });

  factory BaseDriftAllowlist.fromJson(Map<String, dynamic> json) {
    final value = json['allowedBaseDrift'];
    if (value is! List) {
      throw StateError(
          '`allowedBaseDrift` must be a list in `$allowlistPath`.');
    }

    return BaseDriftAllowlist(
      entries: value.map((item) {
        if (item is! Map<String, dynamic>) {
          throw StateError(
            'Each allowlist entry in `$allowlistPath` must be an object.',
          );
        }
        return BaseDriftEntry.fromJson(item);
      }).toList(growable: false),
    );
  }

  final List<BaseDriftEntry> entries;
}

class BaseDriftEntry {
  const BaseDriftEntry({
    required this.path,
    required this.reason,
    required this.bucket,
  });

  factory BaseDriftEntry.fromJson(Map<String, dynamic> json) {
    final path = normalizePath(_readString(json, key: 'path'));
    final reason = _readString(json, key: 'reason');
    final bucket = _readBucket(json);
    return BaseDriftEntry(
      path: path,
      reason: reason,
      bucket: bucket,
    );
  }

  final String path;
  final String reason;
  final String bucket;
}

String _readString(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw StateError('`$key` must be a non-empty string in `$allowlistPath`.');
  }
  return value;
}

String _readBucket(Map<String, dynamic> json) {
  final bucket = _readString(json, key: 'bucket');
  if (!allowedBuckets.contains(bucket)) {
    throw StateError(
      '`bucket` must be one of ${allowedBuckets.toList()} in `$allowlistPath`.',
    );
  }
  return bucket;
}
