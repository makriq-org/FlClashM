import 'dart:convert';
import 'dart:io';

const _baselinePath = 'tool/release_continuity_baseline.json';
const _pubspecPath = 'pubspec.yaml';
const _androidGradlePath = 'android/app/build.gradle.kts';
const _runtimeConstantsPath = 'lib/common/constant.dart';
const _buildWorkflowPath = '.github/workflows/build.yaml';
const _continuityWorkflowPath = '.github/workflows/continuity.yaml';

void main(List<String> args) {
  final baseline = _readBaseline();
  final failures = <String>[];

  final pubspec = _readFile(_pubspecPath, failures);
  final gradle = _readFile(_androidGradlePath, failures);
  final runtimeConstants = _readFile(_runtimeConstantsPath, failures);
  final buildWorkflow = _readFile(_buildWorkflowPath, failures);
  final continuityWorkflow = _readFile(_continuityWorkflowPath, failures);

  if (pubspec != null) {
    _checkVersionCodeFloor(
      pubspec: pubspec,
      versionCodeFloor: baseline.versionCodeFloor,
      failures: failures,
    );
  }

  if (gradle != null) {
    _expectQuotedValue(
      content: gradle,
      pattern: RegExp(r'applicationId\s*=\s*"([^"]+)"'),
      expected: baseline.applicationId,
      label: 'android applicationId',
      failures: failures,
    );
    _checkAndroidSigningContract(gradle: gradle, failures: failures);
  }

  if (runtimeConstants != null) {
    _expectQuotedValue(
      content: runtimeConstants,
      pattern: RegExp(r'const\s+packageName\s*=\s*"([^"]+)";'),
      expected: baseline.applicationId,
      label: 'runtime packageName',
      failures: failures,
    );
    _expectQuotedValue(
      content: runtimeConstants,
      pattern: RegExp(r'const\s+repository\s*=\s*"([^"]+)";'),
      expected: baseline.releaseRepository,
      label: 'runtime release repository',
      failures: failures,
    );
  }

  if (buildWorkflow != null) {
    _checkBuildWorkflow(
      content: buildWorkflow,
      baseline: baseline,
      failures: failures,
    );
  }

  if (continuityWorkflow != null) {
    _checkContinuityWorkflow(
      content: continuityWorkflow,
      failures: failures,
    );
  }

  final githubRepository = _parseGithubRepository(args);
  if (githubRepository != null && githubRepository.isNotEmpty) {
    if (githubRepository != baseline.releaseRepository) {
      failures.add(
        'Workflow repository mismatch: expected '
        '`${baseline.releaseRepository}`, got `$githubRepository`.',
      );
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Release continuity guard failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout
    ..writeln('Release continuity guard passed.')
    ..writeln(
      'versionCode floor: ${baseline.versionCodeFloor}, '
      'release repository: ${baseline.releaseRepository}',
    );
}

String? _parseGithubRepository(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--github-repository') {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for --github-repository');
      }
      return args[i + 1];
    }
    if (arg.startsWith('--github-repository=')) {
      return arg.split('=').last;
    }
  }
  return null;
}

ContinuityBaseline _readBaseline() {
  final file = File(_baselinePath);
  if (!file.existsSync()) {
    throw StateError('Missing continuity baseline file `$_baselinePath`.');
  }
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return ContinuityBaseline.fromJson(data);
}

String? _readFile(String path, List<String> failures) {
  final file = File(path);
  if (!file.existsSync()) {
    failures.add('Missing required file `$path`.');
    return null;
  }
  return file.readAsStringSync();
}

void _checkAndroidSigningContract({
  required String gradle,
  required List<String> failures,
}) {
  _expectPatternExists(
    content: gradle,
    pattern: RegExp(r'file\("keystore\.jks"\)'),
    label: 'release keystore path in `$_androidGradlePath`',
    failures: failures,
  );
  for (final propertyName in const [
    'keyAlias',
    'storePassword',
    'keyPassword'
  ]) {
    _expectPatternExists(
      content: gradle,
      pattern: RegExp('getProperty\\("$propertyName"\\)'),
      label:
          'release signing property `$propertyName` in `$_androidGradlePath`',
      failures: failures,
    );
  }
}

void _checkBuildWorkflow({
  required String content,
  required ContinuityBaseline baseline,
  required List<String> failures,
}) {
  _expectEnvValue(
    content: content,
    name: 'CONTINUITY_RELEASE_REPOSITORY',
    expected: baseline.releaseRepository,
    failures: failures,
  );

  const signingBridgePatterns = <String, String>{
    'KEYSTORE': r'base64\s+--decode\s*>\s*android/app/keystore\.jks',
    'KEY_ALIAS': r'keyAlias=\$\{\{\s*secrets\.KEY_ALIAS\s*\}\}',
    'STORE_PASSWORD': r'storePassword=\$\{\{\s*secrets\.STORE_PASSWORD\s*\}\}',
    'KEY_PASSWORD': r'keyPassword=\$\{\{\s*secrets\.KEY_PASSWORD\s*\}\}',
  };
  for (final secret in baseline.requiredReleaseSecrets) {
    if (!content.contains('secrets.$secret')) {
      failures
          .add('Missing release secret `$secret` in `$_buildWorkflowPath`.');
      continue;
    }
    final pattern = signingBridgePatterns[secret];
    if (pattern != null) {
      _expectPatternExists(
        content: content,
        pattern: RegExp(pattern),
        label: 'workflow signing bridge for `$secret` in `$_buildWorkflowPath`',
        failures: failures,
      );
    }
  }

  _expectPatternExists(
    content: content,
    pattern: RegExp(
      r'https://api\.github\.com/repos/\$(?:\{CONTINUITY_RELEASE_REPOSITORY\}|CONTINUITY_RELEASE_REPOSITORY)/releases/latest',
    ),
    label:
        'release lookup via `CONTINUITY_RELEASE_REPOSITORY` in `$_buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(
      r'dart\s+tool/check_release_continuity\.dart\s+--github-repository\s+"?\$\{GITHUB_REPOSITORY\}"?',
    ),
    label: 'release continuity guard invocation in `$_buildWorkflowPath`',
    failures: failures,
  );
  _expectOrdering(
    content: content,
    labels: const [
      'name: Check release continuity',
      'name: Setup Android signing',
      'name: Build Android release artifacts',
    ],
    description:
        'release continuity guard must run before signing setup and Android release build',
    failures: failures,
  );
}

void _checkVersionCodeFloor({
  required String pubspec,
  required int versionCodeFloor,
  required List<String> failures,
}) {
  final versionMatch =
      RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
  if (versionMatch == null) {
    failures.add('Unable to parse `version` from `$_pubspecPath`.');
    return;
  }

  final version = versionMatch.group(1)!;
  final plusIndex = version.lastIndexOf('+');
  if (plusIndex <= 0 || plusIndex == version.length - 1) {
    failures.add(
      'Expected `pubspec.yaml` version to contain a numeric build suffix, '
      'got `$version`.',
    );
    return;
  }

  final versionCode = int.tryParse(version.substring(plusIndex + 1));
  if (versionCode == null) {
    failures.add('Unable to parse `versionCode` from `$version`.');
    return;
  }

  if (versionCode <= versionCodeFloor) {
    failures.add(
      'Expected `versionCode` > $versionCodeFloor, got $versionCode.',
    );
  }
}

void _expectQuotedValue({
  required String content,
  required RegExp pattern,
  required String expected,
  required String label,
  required List<String> failures,
}) {
  final match = pattern.firstMatch(content);
  if (match == null) {
    failures.add('Unable to locate $label.');
    return;
  }

  final actual = match.group(1);
  if (actual != expected) {
    failures.add('Expected $label `$expected`, got `${actual ?? ''}`.');
  }
}

void _expectEnvValue({
  required String content,
  required String name,
  required String expected,
  required List<String> failures,
}) {
  final match = RegExp('^\\s*$name:\\s*([^\\s#]+)\\s*\$', multiLine: true)
      .firstMatch(content);
  if (match == null) {
    failures.add('Unable to locate `$name` in `$_buildWorkflowPath`.');
    return;
  }

  final actual = match.group(1);
  if (actual != expected) {
    failures.add('Expected `$name: $expected`, got `${actual ?? ''}`.');
  }
}

void _expectPatternExists({
  required String content,
  required RegExp pattern,
  required String label,
  required List<String> failures,
}) {
  if (!pattern.hasMatch(content)) {
    failures.add('Unable to verify $label.');
  }
}

void _expectOrdering({
  required String content,
  required List<String> labels,
  required String description,
  required List<String> failures,
}) {
  var previousIndex = -1;
  for (final label in labels) {
    final currentIndex = content.indexOf(label);
    if (currentIndex == -1) {
      failures.add('Unable to locate `$label` while checking ordering.');
      return;
    }
    if (currentIndex <= previousIndex) {
      failures.add('Expected ordering invariant: $description.');
      return;
    }
    previousIndex = currentIndex;
  }
}

void _checkContinuityWorkflow({
  required String content,
  required List<String> failures,
}) {
  _expectPatternExists(
    content: content,
    pattern: RegExp(r'dart\s+tool/check_release_continuity\.dart(?:\s|$)'),
    label: 'continuity guard invocation in `$_continuityWorkflowPath`',
    failures: failures,
  );
  if (content.contains('--github-repository')) {
    failures.add(
      'Expected `$_continuityWorkflowPath` to skip repository pinning so fork PR/push checks remain usable.',
    );
  }
}

class ContinuityBaseline {
  const ContinuityBaseline({
    required this.applicationId,
    required this.releaseRepository,
    required this.requiredReleaseSecrets,
    required this.versionCodeFloor,
  });

  factory ContinuityBaseline.fromJson(Map<String, dynamic> json) {
    final secrets = json['requiredReleaseSecrets'];
    if (secrets is! List) {
      throw StateError(
        '`requiredReleaseSecrets` must be a list in `$_baselinePath`.',
      );
    }

    return ContinuityBaseline(
      applicationId: json['applicationId'] as String,
      releaseRepository: json['releaseRepository'] as String,
      requiredReleaseSecrets: secrets.cast<String>(),
      versionCodeFloor: json['versionCodeFloor'] as int,
    );
  }

  final String applicationId;
  final String releaseRepository;
  final List<String> requiredReleaseSecrets;
  final int versionCodeFloor;
}
