import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/android_apk_version_codes.dart';

void main() {
  test('reads real package codes and returns the maximum', () async {
    final tempDir = Directory.systemTemp.createTempSync('apk-version-codes-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final codes = <String, int>{
      'FlClashM-android-arm64-v8a.apk': 2026083802,
      'FlClashM-android-x86_64.apk': 2026085802,
    };
    for (final name in codes.keys) {
      File('${tempDir.path}${Platform.pathSeparator}$name')
          .writeAsBytesSync([1]);
    }

    final result = await readAndroidApkVersionCodes(
      distPath: tempDir.path,
      apkNames: codes.keys,
      runner: (executable, arguments) async {
        final name = arguments.last.split(Platform.pathSeparator).last;
        return ProcessResult(1, 0, '${codes[name]}\n', '');
      },
    );

    expect(result.values, codes);
    expect(result.maximum, 2026085802);
  });
}
