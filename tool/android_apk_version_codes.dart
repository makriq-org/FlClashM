import 'dart:io';

typedef ApkAnalyzerRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class AndroidApkVersionCodes {
  AndroidApkVersionCodes(Map<String, int> values)
      : values = Map.unmodifiable(values);

  final Map<String, int> values;

  int get maximum =>
      values.values.reduce((left, right) => left > right ? left : right);
}

Future<AndroidApkVersionCodes> readAndroidApkVersionCodes({
  required String distPath,
  required Iterable<String> apkNames,
  ApkAnalyzerRunner runner = _runApkAnalyzer,
}) async {
  final executable = Platform.environment['APKANALYZER'] ?? 'apkanalyzer';
  final values = <String, int>{};
  for (final name in apkNames.toList()..sort()) {
    final file = File(_join(distPath, name));
    if (!file.existsSync()) {
      throw StateError('Missing Android APK `${file.path}`.');
    }
    final result = await runner(
      executable,
      ['manifest', 'version-code', file.path],
    );
    final raw = result.stdout.toString().trim();
    final versionCode = int.tryParse(raw);
    if (result.exitCode != 0 || versionCode == null || versionCode <= 0) {
      throw StateError(
        'Unable to read Android versionCode from `${file.path}`: '
        '${result.stderr.toString().trim()}',
      );
    }
    values[name] = versionCode;
  }
  if (values.isEmpty) {
    throw StateError('No Android APK artifacts found in `$distPath`.');
  }
  return AndroidApkVersionCodes(values);
}

Future<ProcessResult> _runApkAnalyzer(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

String _join(String left, String right) => left.endsWith(Platform.pathSeparator)
    ? '$left$right'
    : '$left${Platform.pathSeparator}$right';
