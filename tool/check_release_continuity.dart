import 'dart:io';

import 'release_contract.dart';

void main(List<String> args) {
  final options = GuardOptions.parse(args);
  final contract = readReleaseContract();
  final failures = <String>[];

  final pubspec = readFileIfExists(pubspecPath, failures);
  final gradle = readFileIfExists(androidGradlePath, failures);
  final runtimeConstants = readFileIfExists(runtimeConstantsPath, failures);
  final buildWorkflow = readFileIfExists(buildWorkflowPath, failures);
  final continuityWorkflow = readFileIfExists(continuityWorkflowPath, failures);
  final setup = readFileIfExists(setupPath, failures);
  final releaseTemplate = readFileIfExists(releaseTemplatePath, failures);
  final preReleaseTemplate = readFileIfExists(preReleaseTemplatePath, failures);

  if (pubspec != null) {
    final pubspecVersion = tryParsePubspecVersion(
      pubspec,
      path: pubspecPath,
      failures: failures,
    );
    if (pubspecVersion != null) {
      _checkVersionCodeFloor(
        pubspecVersion: pubspecVersion,
        versionCodeFloor: contract.versionCodeFloor,
        failures: failures,
      );
      if (options.githubRefName != null && options.githubRefName!.isNotEmpty) {
        _checkTagContract(
          refName: options.githubRefName!,
          pubspecVersion: pubspecVersion,
          failures: failures,
        );
      }
    }
  }

  if (gradle != null) {
    _expectQuotedValue(
      content: gradle,
      pattern: RegExp(r'applicationId\s*=\s*"([^"]+)"'),
      expected: contract.applicationId,
      label: 'android applicationId',
      failures: failures,
    );
    _checkAndroidSigningContract(gradle: gradle, failures: failures);
  }

  if (runtimeConstants != null) {
    _expectQuotedValue(
      content: runtimeConstants,
      pattern: RegExp(r'const\s+packageName\s*=\s*"([^"]+)";'),
      expected: contract.applicationId,
      label: 'runtime packageName',
      failures: failures,
    );
    _expectQuotedValue(
      content: runtimeConstants,
      pattern: RegExp(r'const\s+repository\s*=\s*"([^"]+)";'),
      expected: contract.releaseRepository,
      label: 'runtime release repository',
      failures: failures,
    );
  }

  if (setup != null) {
    _checkSetupContract(
      content: setup,
      contract: contract,
      failures: failures,
    );
  }

  if (releaseTemplate != null) {
    _checkReleaseTemplate(
      content: releaseTemplate,
      contract: contract,
      templatePath: releaseTemplatePath,
      failures: failures,
    );
  }

  if (preReleaseTemplate != null) {
    _checkReleaseTemplate(
      content: preReleaseTemplate,
      contract: contract,
      templatePath: preReleaseTemplatePath,
      failures: failures,
    );
  }

  if (buildWorkflow != null) {
    _checkBuildWorkflow(
      content: buildWorkflow,
      contract: contract,
      failures: failures,
    );
  }

  if (continuityWorkflow != null) {
    _checkContinuityWorkflow(
      content: continuityWorkflow,
      failures: failures,
    );
  }

  if (options.githubRepository != null &&
      options.githubRepository!.isNotEmpty) {
    if (options.githubRepository != contract.releaseRepository) {
      failures.add(
        'Workflow repository mismatch: expected '
        '`${contract.releaseRepository}`, got `${options.githubRepository}`.',
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
      'versionCode floor: ${contract.versionCodeFloor}, '
      'release repository: ${contract.releaseRepository}',
    );
}

class GuardOptions {
  const GuardOptions({
    this.githubRepository,
    this.githubRefName,
  });

  factory GuardOptions.parse(List<String> args) {
    String? githubRepository;
    String? githubRefName;

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '--github-repository') {
        if (index + 1 >= args.length) {
          throw ArgumentError('Missing value for --github-repository');
        }
        githubRepository = args[++index];
        continue;
      }
      if (arg.startsWith('--github-repository=')) {
        githubRepository = arg.substring('--github-repository='.length);
        continue;
      }
      if (arg == '--github-ref-name') {
        if (index + 1 >= args.length) {
          throw ArgumentError('Missing value for --github-ref-name');
        }
        githubRefName = args[++index];
        continue;
      }
      if (arg.startsWith('--github-ref-name=')) {
        githubRefName = arg.substring('--github-ref-name='.length);
        continue;
      }
      throw ArgumentError('Unknown argument: $arg');
    }

    return GuardOptions(
      githubRepository: githubRepository,
      githubRefName: githubRefName,
    );
  }

  final String? githubRepository;
  final String? githubRefName;
}

void _checkAndroidSigningContract({
  required String gradle,
  required List<String> failures,
}) {
  _expectPatternExists(
    content: gradle,
    pattern: RegExp(r'file\("keystore\.jks"\)'),
    label: 'release keystore path in `$androidGradlePath`',
    failures: failures,
  );
  for (final propertyName in const [
    'keyAlias',
    'storePassword',
    'keyPassword',
  ]) {
    _expectPatternExists(
      content: gradle,
      pattern: RegExp('getProperty\\("$propertyName"\\)'),
      label: 'release signing property `$propertyName` in `$androidGradlePath`',
      failures: failures,
    );
  }
  _expectPatternExists(
    content: gradle,
    pattern: RegExp(r'applicationIdSuffix\s*=\s*"\.dev"'),
    label: 'debug-signed fallback package suffix in `$androidGradlePath`',
    failures: failures,
  );
}

void _checkBuildWorkflow({
  required String content,
  required ReleaseContract contract,
  required List<String> failures,
}) {
  _expectEnvValue(
    content: content,
    name: 'CONTINUITY_RELEASE_REPOSITORY',
    expected: contract.releaseRepository,
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern:
        RegExp(r"HAS_RELEASE_SIGNING:\s*\$\{\{\s*secrets\.KEYSTORE\s*!=\s*''"),
    label: 'release signing presence gate in `$buildWorkflowPath`',
    failures: failures,
  );

  const signingBridgePatterns = <String, String>{
    'KEYSTORE': r'base64\s+--decode\s*>\s*android/app/keystore\.jks',
    'KEY_ALIAS': r'keyAlias=\$\{\{\s*secrets\.KEY_ALIAS\s*\}\}',
    'STORE_PASSWORD': r'storePassword=\$\{\{\s*secrets\.STORE_PASSWORD\s*\}\}',
    'KEY_PASSWORD': r'keyPassword=\$\{\{\s*secrets\.KEY_PASSWORD\s*\}\}',
  };
  for (final secret in contract.requiredReleaseSecrets) {
    if (!content.contains('secrets.$secret')) {
      failures.add('Missing release secret `$secret` in `$buildWorkflowPath`.');
      continue;
    }
    final pattern = signingBridgePatterns[secret];
    if (pattern != null) {
      _expectPatternExists(
        content: content,
        pattern: RegExp(pattern),
        label: 'workflow signing bridge for `$secret` in `$buildWorkflowPath`',
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
        'release lookup via `CONTINUITY_RELEASE_REPOSITORY` in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(r'dart\s+tool/check_release_continuity\.dart(?:\s|$)'),
    label: 'release continuity guard invocation in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(r'--github-repository\s+"?\$\{GITHUB_REPOSITORY\}"?'),
    label: 'release continuity repository pin in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(
      r'--github-ref-name\s+"?\$\{\{\s*github\.ref_name\s*\}\}"?',
    ),
    label: 'release continuity tag pin in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(r'dart\s+tool/write_release_metadata\.dart(?:\s|$)'),
    label: 'release metadata generation in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(
      r'dart\s+tool/check_android_release_signing\.dart\s+dist/FlClashM-android-arm64-v8a\.apk',
    ),
    label: 'release signing continuity check in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern: RegExp(
      '--out\\s+dist/${RegExp.escape(contract.releaseMetadataFileName)}',
    ),
    label: 'release metadata output path in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectPatternExists(
    content: content,
    pattern:
        RegExp(r'dart\s+tool/check_android_release_artifacts\.dart(?:\s|$)'),
    label: 'release artifact guard in `$buildWorkflowPath`',
    failures: failures,
  );
  _expectOrdering(
    content: content,
    labels: const [
      'name: Check release continuity',
      'name: Require continuity signing for tag releases',
      'name: Setup Android signing',
      'name: Build Android core artifacts',
      r'name: Build Android ${{ matrix.out }} artifact',
      'name: Assert Android release signing continuity',
      'name: Generate release metadata',
      'name: Generate sha256',
      'name: Assert Android release artifacts',
    ],
    description:
        'release continuity guard must run before signing, build, metadata and artifact assertions',
    failures: failures,
  );
}

void _checkSetupContract({
  required String content,
  required ReleaseContract contract,
  required List<String> failures,
}) {
  _expectQuotedValue(
    content: content,
    pattern: RegExp(r"const _appName = '([^']+)';"),
    expected: contract.appName,
    label: 'release app name in `$setupPath`',
    failures: failures,
  );

  for (final artifact in contract.releaseArtifacts) {
    final expectedSourceName =
        artifact.replaceFirst(contract.appName, r'$_appName');
    _expectPatternExists(
      content: content,
      pattern: RegExp(RegExp.escape(expectedSourceName)),
      label: 'release artifact `$artifact` target in `$setupPath`',
      failures: failures,
    );
  }
}

void _checkReleaseTemplate({
  required String content,
  required ReleaseContract contract,
  required String templatePath,
  required List<String> failures,
}) {
  final lines = content
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final bulletLines = lines.where((line) => line.startsWith('- ')).toList();

  if (lines.isEmpty || lines.length > 3) {
    failures.add(
      'Release template `$templatePath` must contain 1-3 non-empty bullet points.',
    );
  }

  if (bulletLines.length != lines.length) {
    failures.add(
      'Release template `$templatePath` must contain only Markdown bullet lines.',
    );
  }

  if (!content.contains('VERSION')) {
    failures.add('Release template `$templatePath` must keep VERSION placeholder.');
  }

  if (!content.contains(contract.appName)) {
    failures.add('Release template `$templatePath` must mention `${contract.appName}`.');
  }

  if (RegExp(r'https?://|<[^>]+>|CHANGELOG|ChangeLog|changelog|img\.shields')
      .hasMatch(content)) {
    failures.add(
      'Release template `$templatePath` must stay concise: no links, HTML, badges or changelog references.',
    );
  }

  final cyrillic = RegExp(r'[А-Яа-яЁё]');
  for (final line in bulletLines) {
    if (!cyrillic.hasMatch(line)) {
      failures.add(
        'Release template `$templatePath` must use Russian text in every bullet.',
      );
    }
  }
}

void _checkContinuityWorkflow({
  required String content,
  required List<String> failures,
}) {
  _expectPatternExists(
    content: content,
    pattern: RegExp(r'dart\s+tool/check_release_continuity\.dart(?:\s|$)'),
    label: 'continuity guard invocation in `$continuityWorkflowPath`',
    failures: failures,
  );
  if (content.contains('--github-repository')) {
    failures.add(
      'Expected `$continuityWorkflowPath` to skip repository pinning so fork PR/push checks remain usable.',
    );
  }
  if (content.contains('--github-ref-name')) {
    failures.add(
      'Expected `$continuityWorkflowPath` to skip tag pinning so branch PR/push checks remain usable.',
    );
  }
}

void _checkTagContract({
  required String refName,
  required PubspecVersion pubspecVersion,
  required List<String> failures,
}) {
  final expectedStableTag = 'v${pubspecVersion.versionName}';
  if (!refName.startsWith('v')) {
    failures.add(
      'Expected release tag to start with `v`, got `$refName`.',
    );
    return;
  }

  if (refName.contains('-')) {
    final expectedPrefix = '$expectedStableTag-';
    if (!refName.startsWith(expectedPrefix) || refName == expectedPrefix) {
      failures.add(
        'Expected pre-release tag to start with `$expectedPrefix`, got `$refName`.',
      );
    }
    return;
  }

  if (refName != expectedStableTag) {
    failures.add(
      'Expected stable release tag `$expectedStableTag`, got `$refName`.',
    );
  }
}

void _checkVersionCodeFloor({
  required PubspecVersion pubspecVersion,
  required int versionCodeFloor,
  required List<String> failures,
}) {
  if (pubspecVersion.versionCode <= versionCodeFloor) {
    failures.add(
      'Expected `versionCode` > $versionCodeFloor, got ${pubspecVersion.versionCode}.',
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
    failures.add('Unable to locate `$name` in `$buildWorkflowPath`.');
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
