import 'dart:convert';
import 'dart:io';

const baselinePath = 'tool/release_continuity_baseline.json';
const pubspecPath = 'pubspec.yaml';
const androidGradlePath = 'android/app/build.gradle.kts';
const runtimeConstantsPath = 'lib/common/constant.dart';
const appUpdateManifestPath = 'lib/product/services/app_update_manifest.dart';
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

  final versionName = raw.substring(0, plusIndex);
  if (!RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-pre[1-9]\d*)?$',
  ).hasMatch(versionName)) {
    throw StateError(
      'Expected `$path` versionName to use `MAJOR.MINOR.PATCH` or '
      '`MAJOR.MINOR.PATCH-preN`, got `$versionName`.',
    );
  }

  return PubspecVersion(
    raw: raw,
    versionName: versionName,
    versionCode: versionCode,
  );
}

String? validateReleaseTag({
  required String refName,
  required PubspecVersion pubspecVersion,
}) {
  if (!refName.startsWith('v')) {
    return 'Expected release tag to start with `v`, got `$refName`.';
  }
  if (refName != pubspecVersion.tagName) {
    return 'Expected release tag `${pubspecVersion.tagName}` to exactly match '
        'the pubspec version, got `$refName`.';
  }
  return null;
}

String? validateReleaseChannel({
  required String releaseChannel,
  required PubspecVersion pubspecVersion,
}) {
  if (releaseChannel != pubspecVersion.releaseChannel) {
    return 'Expected release channel `${pubspecVersion.releaseChannel}` for '
        '`${pubspecVersion.versionName}`, got `$releaseChannel`.';
  }
  return null;
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
    required this.appUpdate,
    required this.requiredReleaseSecrets,
    required this.continuitySigner,
    required this.versionCodeFloor,
    required this.releaseArtifacts,
    required this.releaseMetadataFileName,
  });

  factory ReleaseContract.fromJson(Map<String, dynamic> json) =>
      ReleaseContract(
        applicationId: _readString(json, key: 'applicationId'),
        releaseRepository: _readString(json, key: 'releaseRepository'),
        appUpdate: AppUpdateContract.fromJson(
          _readMap(json, key: 'appUpdate'),
        ),
        requiredReleaseSecrets: _readStringList(
          json,
          key: 'requiredReleaseSecrets',
        ),
        continuitySigner: ReleaseSigner.fromJson(
          _readMap(json, key: 'continuitySigner'),
        ),
        versionCodeFloor: _readInt(json, key: 'versionCodeFloor'),
        releaseArtifacts: _readStringList(json, key: 'releaseArtifacts'),
        releaseMetadataFileName: _readString(
          json,
          key: 'releaseMetadataFileName',
        ),
      );

  final String applicationId;
  final String releaseRepository;
  final AppUpdateContract appUpdate;
  final List<String> requiredReleaseSecrets;
  final ReleaseSigner continuitySigner;
  final int versionCodeFloor;
  final List<String> releaseArtifacts;
  final String releaseMetadataFileName;

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

class AppUpdateContract {
  const AppUpdateContract({
    required this.sourceForgeProject,
    required this.manifestPublicKeyBase64,
  });

  factory AppUpdateContract.fromJson(Map<String, dynamic> json) =>
      AppUpdateContract(
        sourceForgeProject: _readString(
          json,
          key: 'sourceForgeProject',
        ),
        manifestPublicKeyBase64: _readString(
          json,
          key: 'manifestPublicKeyBase64',
        ),
      );

  final String sourceForgeProject;
  final String manifestPublicKeyBase64;
}

class ReleaseSigner {
  const ReleaseSigner({
    required this.subjectDn,
    required this.sha256,
  });

  factory ReleaseSigner.fromJson(Map<String, dynamic> json) => ReleaseSigner(
        subjectDn: _readString(json, key: 'subjectDn'),
        sha256: _readString(json, key: 'sha256').toLowerCase(),
      );

  final String subjectDn;
  final String sha256;
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

  bool get isPrerelease => versionName.contains('-');
  String get stableVersionName => versionName.split('-').first;
  String get tagName => 'v$versionName';
  String get stableTagName => 'v$stableVersionName';
  String get releaseChannel => isPrerelease ? 'pre' : 'stable';
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
