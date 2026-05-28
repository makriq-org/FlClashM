import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'release_contract.dart';

Future<void> main(List<String> args) async {
  final options = ArtifactCheckOptions.parse(args);
  final contract = readReleaseContract();
  final pubspecVersion = readPubspecVersion();
  final coreVersion = readCoreVersion();
  final failures = <String>[];

  final distDirectory = Directory(options.distPath);
  if (!distDirectory.existsSync()) {
    failures.add('Missing dist directory `${distDirectory.path}`.');
  }

  final releaseFileNames = [
    ...contract.releaseArtifacts,
    contract.releaseMetadataFileName,
  ];
  final releaseFiles = <String, File>{};

  for (final fileName in releaseFileNames) {
    final file = File(_join(distDirectory.path, fileName));
    releaseFiles[fileName] = file;
    if (!file.existsSync()) {
      failures.add('Missing release artifact `${file.path}`.');
      continue;
    }
    if (file.lengthSync() <= 0) {
      failures.add('Release artifact `${file.path}` is empty.');
    }
  }

  final metadataFile = releaseFiles[contract.releaseMetadataFileName];
  if (metadataFile != null && metadataFile.existsSync()) {
    final metadata = _readJsonFile(metadataFile, failures);
    if (metadata != null) {
      _checkMetadataContract(
        metadata: metadata,
        contract: contract,
        pubspecVersion: pubspecVersion,
        coreVersion: coreVersion,
        options: options,
        failures: failures,
      );
    }
  }

  if (options.releaseChannel == 'stable') {
    for (final entry in releaseFiles.entries) {
      final artifact = entry.value;
      if (!artifact.existsSync()) {
        continue;
      }
      final sidecar = File('${artifact.path}.sha256');
      if (!sidecar.existsSync()) {
        failures.add('Missing checksum sidecar `${sidecar.path}`.');
        continue;
      }
      final declaredHash = _parseSha256Content(
        sidecar.readAsStringSync(),
        assetName: entry.key,
      );
      if (declaredHash == null) {
        failures.add('Unable to parse checksum sidecar `${sidecar.path}`.');
        continue;
      }
      final actualHash = await _computeSha256(artifact);
      if (declaredHash != actualHash) {
        failures.add(
          'Checksum mismatch for `${artifact.path}`: expected '
          '`$declaredHash`, got `$actualHash`.',
        );
      }
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Android release artifact guard failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Android release artifact guard passed for `${distDirectory.path}` '
    '(${options.releaseChannel}).',
  );
}

class ArtifactCheckOptions {
  const ArtifactCheckOptions({
    required this.distPath,
    required this.releaseChannel,
    this.githubRefName,
    this.githubRepository,
  });

  factory ArtifactCheckOptions.parse(List<String> args) {
    var distPath = 'dist';
    String? releaseChannel;
    String? githubRefName;
    String? githubRepository;

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '--dist') {
        distPath = _requireValue(args, index, '--dist');
        index++;
        continue;
      }
      if (arg.startsWith('--dist=')) {
        distPath = arg.substring('--dist='.length);
        continue;
      }
      if (arg == '--release-channel') {
        releaseChannel = _requireValue(args, index, '--release-channel');
        index++;
        continue;
      }
      if (arg.startsWith('--release-channel=')) {
        releaseChannel = arg.substring('--release-channel='.length);
        continue;
      }
      if (arg == '--github-ref-name') {
        githubRefName = _requireValue(args, index, '--github-ref-name');
        index++;
        continue;
      }
      if (arg.startsWith('--github-ref-name=')) {
        githubRefName = arg.substring('--github-ref-name='.length);
        continue;
      }
      if (arg == '--github-repository') {
        githubRepository = _requireValue(args, index, '--github-repository');
        index++;
        continue;
      }
      if (arg.startsWith('--github-repository=')) {
        githubRepository = arg.substring('--github-repository='.length);
        continue;
      }
      throw ArgumentError('Unknown argument: $arg');
    }

    if (releaseChannel != 'stable' && releaseChannel != 'pre') {
      throw ArgumentError(
        'Expected `--release-channel stable|pre`, got `${releaseChannel ?? ''}`.',
      );
    }

    return ArtifactCheckOptions(
      distPath: distPath,
      releaseChannel: releaseChannel!,
      githubRefName: githubRefName,
      githubRepository: githubRepository,
    );
  }

  final String distPath;
  final String releaseChannel;
  final String? githubRefName;
  final String? githubRepository;
}

void _checkMetadataContract({
  required Map<String, dynamic> metadata,
  required ReleaseContract contract,
  required PubspecVersion pubspecVersion,
  required String coreVersion,
  required ArtifactCheckOptions options,
  required List<String> failures,
}) {
  _expectJsonInt(
    metadata,
    key: 'schemaVersion',
    expected: 1,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'appName',
    expected: contract.appName,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'applicationId',
    expected: contract.applicationId,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'releaseRepository',
    expected: contract.releaseRepository,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'expectedStableTag',
    expected: 'v${pubspecVersion.versionName}',
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'releaseChannel',
    expected: options.releaseChannel,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'pubspecVersion',
    expected: pubspecVersion.raw,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'versionName',
    expected: pubspecVersion.versionName,
    failures: failures,
  );
  _expectJsonInt(
    metadata,
    key: 'versionCode',
    expected: pubspecVersion.versionCode,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'coreVersion',
    expected: coreVersion,
    failures: failures,
  );
  _expectJsonString(
    metadata,
    key: 'releaseMetadataFileName',
    expected: contract.releaseMetadataFileName,
    failures: failures,
  );
  _expectJsonStringList(
    metadata,
    key: 'releaseArtifacts',
    expected: contract.releaseArtifacts,
    failures: failures,
  );

  final tagName = options.githubRefName;
  if (tagName != null && tagName.isNotEmpty) {
    _expectJsonString(
      metadata,
      key: 'tagName',
      expected: tagName,
      failures: failures,
    );
  }

  final githubRepository = options.githubRepository;
  if (githubRepository != null && githubRepository.isNotEmpty) {
    _expectJsonString(
      metadata,
      key: 'githubRepository',
      expected: githubRepository,
      failures: failures,
    );
  }

  final continuity = metadata['continuity'];
  if (continuity is! Map<String, dynamic>) {
    failures.add('Expected `continuity` object in release metadata.');
    return;
  }

  _expectJsonString(
    continuity,
    key: 'sourceProject',
    expected: contract.continuityBaseline.sourceProject,
    failures: failures,
  );
  _expectJsonString(
    continuity,
    key: 'sourceTag',
    expected: contract.continuityBaseline.sourceTag,
    failures: failures,
  );
  _expectJsonString(
    continuity,
    key: 'publishedAt',
    expected: contract.continuityBaseline.publishedAt,
    failures: failures,
  );
  _expectJsonString(
    continuity,
    key: 'sourcePubspecVersion',
    expected: contract.continuityBaseline.sourcePubspecVersion,
    failures: failures,
  );
  _expectJsonInt(
    continuity,
    key: 'versionCodeFloor',
    expected: contract.versionCodeFloor,
    failures: failures,
  );
}

Map<String, dynamic>? _readJsonFile(File file, List<String> failures) {
  try {
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map<String, dynamic>) {
      failures.add('Expected JSON object in `${file.path}`.');
      return null;
    }
    return data;
  } on FormatException catch (error) {
    failures.add('Invalid JSON in `${file.path}`: ${error.message}');
    return null;
  }
}

Future<String> _computeSha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

String? _parseSha256Content(
  String content, {
  required String assetName,
}) {
  String? fallbackHash;
  var sawNamedEntry = false;

  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }

    final hashFirstMatch = RegExp(
      r'^([a-fA-F0-9]{64})\s+[*]?(.+)$',
    ).firstMatch(line);
    if (hashFirstMatch != null) {
      sawNamedEntry = true;
      final candidateName = hashFirstMatch.group(2)!.trim();
      if (_matchesAssetName(candidateName, assetName)) {
        return hashFirstMatch.group(1)!.toLowerCase();
      }
      continue;
    }

    final digestOnlyMatch = RegExp(
      r'^(?:sha256:)?([a-fA-F0-9]{64})$',
      caseSensitive: false,
    ).firstMatch(line);
    if (digestOnlyMatch != null) {
      fallbackHash ??= digestOnlyMatch.group(1)!.toLowerCase();
    }
  }

  if (sawNamedEntry) {
    return null;
  }
  return fallbackHash;
}

bool _matchesAssetName(String rawAssetName, String expectedAssetName) {
  final trimmed = rawAssetName.trim();
  if (trimmed == expectedAssetName) {
    return true;
  }
  final segments = trimmed.split(RegExp(r'[\\/]'));
  return segments.isNotEmpty && segments.last == expectedAssetName;
}

void _expectJsonString(
  Map<String, dynamic> json, {
  required String key,
  required String expected,
  required List<String> failures,
}) {
  final value = json[key];
  if (value is! String) {
    failures.add('Expected string `$key` in release metadata.');
    return;
  }
  if (value != expected) {
    failures
        .add('Expected `$key: $expected`, got `$value` in release metadata.');
  }
}

void _expectJsonInt(
  Map<String, dynamic> json, {
  required String key,
  required int expected,
  required List<String> failures,
}) {
  final value = json[key];
  if (value is! int) {
    failures.add('Expected int `$key` in release metadata.');
    return;
  }
  if (value != expected) {
    failures
        .add('Expected `$key: $expected`, got `$value` in release metadata.');
  }
}

void _expectJsonStringList(
  Map<String, dynamic> json, {
  required String key,
  required List<String> expected,
  required List<String> failures,
}) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    failures.add('Expected string list `$key` in release metadata.');
    return;
  }
  final actual = value.cast<String>();
  if (actual.length != expected.length) {
    failures.add(
      'Expected `$key` length ${expected.length}, got ${actual.length} in release metadata.',
    );
    return;
  }
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) {
      failures.add(
        'Expected `$key[$index]: ${expected[index]}`, got `${actual[index]}` in release metadata.',
      );
    }
  }
}

String _requireValue(List<String> args, int index, String flag) {
  if (index + 1 >= args.length) {
    throw ArgumentError('Missing value for $flag');
  }
  return args[index + 1];
}

String _join(String base, String leaf) => base.endsWith(Platform.pathSeparator)
    ? '$base$leaf'
    : '$base${Platform.pathSeparator}$leaf';
