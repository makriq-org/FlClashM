import 'dart:io';

import 'release_contract.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart tool/check_android_release_signing.dart <apk-path>',
    );
    exitCode = 64;
    return;
  }

  final apkPath = args.single;
  final apkFile = File(apkPath);
  if (!apkFile.existsSync()) {
    stderr.writeln('APK not found: $apkPath');
    exitCode = 1;
    return;
  }

  final contract = readReleaseContract();
  final apksignerPath = _resolveApkSigner();
  final result = Process.runSync(
    apksignerPath,
    ['verify', '--print-certs', apkFile.path],
    runInShell: true,
  );

  if (result.exitCode != 0) {
    stderr
      ..writeln('apksigner verify failed for ${apkFile.path}')
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    exitCode = result.exitCode;
    return;
  }

  final output = '${result.stdout}\n${result.stderr}';
  final shaMatch = RegExp(
    r'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]+)',
  ).firstMatch(output);
  final dnMatch =
      RegExp(r'Signer #1 certificate DN:\s*(.+)').firstMatch(output);

  final actualSha256 = shaMatch?.group(1)?.toLowerCase();
  final actualDn = dnMatch?.group(1)?.trim();

  if (actualSha256 == null || actualDn == null) {
    stderr
      ..writeln('Unable to parse signer information from apksigner output.')
      ..writeln(output);
    exitCode = 1;
    return;
  }

  final expectedSigner = contract.continuitySigner;
  if (actualSha256 != expectedSigner.sha256) {
    stderr
      ..writeln(
        'Release signing mismatch: expected SHA-256 '
        '${expectedSigner.sha256}, got $actualSha256.',
      )
      ..writeln('Expected signer DN: ${expectedSigner.subjectDn}')
      ..writeln('Actual signer DN:   $actualDn');
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Android release signing OK: $actualDn (${expectedSigner.sha256})',
  );
}

String _resolveApkSigner() {
  final sdkRoot = Platform.environment['ANDROID_SDK_ROOT'] ??
      Platform.environment['ANDROID_HOME'];
  if (sdkRoot == null || sdkRoot.isEmpty) {
    throw StateError(
      'ANDROID_SDK_ROOT or ANDROID_HOME must be set to locate apksigner.',
    );
  }

  final buildToolsDir = Directory(_join(sdkRoot, 'build-tools'));
  if (!buildToolsDir.existsSync()) {
    throw StateError('Android build-tools directory not found in $sdkRoot.');
  }

  final candidates = buildToolsDir
      .listSync()
      .whereType<Directory>()
      .map((dir) => File(_join(dir.path, 'apksigner')))
      .where((file) => file.existsSync())
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (candidates.isEmpty) {
    throw StateError('Unable to find apksigner under $sdkRoot/build-tools.');
  }

  return candidates.last.path;
}

String _join(String first, [String? second, String? third]) {
  final parts = [first, second, third]
      .whereType<String>()
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.join(Platform.pathSeparator);
}
