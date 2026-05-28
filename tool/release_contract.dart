import 'dart:convert';
import 'dart:io';

const baselinePath = 'tool/release_continuity_baseline.json';
const pubspecPath = 'pubspec.yaml';
const androidGradlePath = 'android/app/build.gradle.kts';
const runtimeConstantsPath = 'lib/common/constant.dart';
const buildWorkflowPath = '.github/workflows/build.yaml';
const continuityWorkflowPath = '.github/workflows/continuity.yaml';
const setupPath = 'setup.dart';
const releaseTemplatePath = '.github/release_template.md';
const preReleaseTemplatePath = '.github/pre_release_template.md';
const coreVersionPath = 'lib/core_version.dart';

ReleaseContract readReleaseContract() {
  final file = File(baselinePath);
  if (!file.existsSync()) {
    throw StateError('Missing release contract file `$baselinePath`.');
  }
  final data = jsonDecode(file.readAsStringSync());
  if (data is! Map<String, dynamic>) {
    throw StateError('Expected `$baselinePath` to contain a JSON object.');
  }
  return ReleaseContract.fromJson(data);
}

String readRequiredFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Missing required file `$path`.');
  }
  return file.readAsStringSync();
}

String? readFileIfExists(String path, List<String> failures) {
  final file = File(path);
  if (!file.existsSync()) {
    failures.add('Missing required file `$path`.');
    return null;
  }
  return file.readAsStringSync();
}

PubspecVersion readPubspecVersion() =>
    parsePubspecVersion(readRequiredFile(pubspecPath), path: pubspecPath);

PubspecVersion parsePubspecVersion(
  String content, {
  required String path,
}) {
  final versionMatch =
      RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(content);
  if (versionMatch == null) {
    throw StateError('Unable to parse `version` from `$path`.');
  }

  final raw = versionMatch.group(1)!;
  final plusIndex = raw.lastIndexOf('+');
  if (plusIndex <= 0 || plusIndex == raw.length - 1) {
    throw StateError(
      'Expected `$path` version to contain a numeric build suffix, got `$raw`.',
    );
  }

  final versionCode = int.tryParse(raw.substring(plusIndex + 1));
  if (versionCode == null) {
    throw StateError('Unable to parse `versionCode` from `$raw` in `$path`.');
  }

  return PubspecVersion(
    raw: raw,
    versionName: raw.substring(0, plusIndex),
    versionCode: versionCode,
  );
}

PubspecVersion? tryParsePubspecVersion(
  String content, {
  required String path,
  required List<String> failures,
}) {
  try {
    return parsePubspecVersion(content, path: path);
  } on Object catch (error) {
    failures.add('$error');
    return null;
  }
}

String readCoreVersion() =>
    parseCoreVersion(readRequiredFile(coreVersionPath), path: coreVersionPath);

String parseCoreVersion(
  String content, {
  required String path,
}) {
  final match = RegExp(
    r"^const String kCoreVersionFromSource = '([^']+)';$",
    multiLine: true,
  ).firstMatch(content);
  if (match == null) {
    throw StateError('Unable to parse `kCoreVersionFromSource` from `$path`.');
  }
  return match.group(1)!;
}

String? tryParseCoreVersion(
  String content, {
  required String path,
  required List<String> failures,
}) {
  try {
    return parseCoreVersion(content, path: path);
  } on Object catch (error) {
    failures.add('$error');
    return null;
  }
}

class ReleaseContract {
  const ReleaseContract({
    required this.applicationId,
    required this.releaseRepository,
    required this.requiredReleaseSecrets,
    required this.versionCodeFloor,
    required this.releaseArtifacts,
    required this.releaseMetadataFileName,
    required this.continuityBaseline,
  });

  factory ReleaseContract.fromJson(Map<String, dynamic> json) =>
      ReleaseContract(
        applicationId: _readString(json, key: 'applicationId'),
        releaseRepository: _readString(json, key: 'releaseRepository'),
        requiredReleaseSecrets: _readStringList(
          json,
          key: 'requiredReleaseSecrets',
        ),
        versionCodeFloor: _readInt(json, key: 'versionCodeFloor'),
        releaseArtifacts: _readStringList(json, key: 'releaseArtifacts'),
        releaseMetadataFileName: _readString(
          json,
          key: 'releaseMetadataFileName',
        ),
        continuityBaseline: ContinuityBaseline.fromJson(
          _readMap(json, key: 'continuityBaseline'),
        ),
      );

  final String applicationId;
  final String releaseRepository;
  final List<String> requiredReleaseSecrets;
  final int versionCodeFloor;
  final List<String> releaseArtifacts;
  final String releaseMetadataFileName;
  final ContinuityBaseline continuityBaseline;

  String get appName {
    if (releaseArtifacts.isEmpty) {
      throw StateError(
          'Expected non-empty `releaseArtifacts` in `$baselinePath`.');
    }
    final artifact = releaseArtifacts.first;
    final markerIndex = artifact.indexOf('-android');
    if (markerIndex <= 0) {
      throw StateError(
        'Unable to derive app name from release artifact `$artifact`.',
      );
    }
    return artifact.substring(0, markerIndex);
  }
}

class ContinuityBaseline {
  const ContinuityBaseline({
    required this.sourceProject,
    required this.sourceTag,
    required this.publishedAt,
    required this.sourcePubspecVersion,
  });

  factory ContinuityBaseline.fromJson(Map<String, dynamic> json) =>
      ContinuityBaseline(
        sourceProject: _readString(json, key: 'sourceProject'),
        sourceTag: _readString(json, key: 'sourceTag'),
        publishedAt: _readString(json, key: 'publishedAt'),
        sourcePubspecVersion: _readString(json, key: 'sourcePubspecVersion'),
      );

  final String sourceProject;
  final String sourceTag;
  final String publishedAt;
  final String sourcePubspecVersion;

  Map<String, Object?> toJson({
    required int versionCodeFloor,
  }) =>
      {
        'sourceProject': sourceProject,
        'sourceTag': sourceTag,
        'publishedAt': publishedAt,
        'sourcePubspecVersion': sourcePubspecVersion,
        'versionCodeFloor': versionCodeFloor,
      };
}

class PubspecVersion {
  const PubspecVersion({
    required this.raw,
    required this.versionName,
    required this.versionCode,
  });

  final String raw;
  final String versionName;
  final int versionCode;
}

Map<String, dynamic> _readMap(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! Map<String, dynamic>) {
    throw StateError('`$key` must be an object in `$baselinePath`.');
  }
  return value;
}

String _readString(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw StateError('`$key` must be a non-empty string in `$baselinePath`.');
  }
  return value;
}

int _readInt(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! int) {
    throw StateError('`$key` must be an int in `$baselinePath`.');
  }
  return value;
}

List<String> _readStringList(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw StateError('`$key` must be a string list in `$baselinePath`.');
  }
  return value.cast<String>();
}
