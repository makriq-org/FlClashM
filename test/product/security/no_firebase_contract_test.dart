import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Firebase telemetry stays absent from Android and app contracts', () {
    const forbiddenMarkers = <String, List<String>>{
      'android/settings.gradle.kts': [
        'com.google.gms.google-services',
        'com.google.firebase.crashlytics',
      ],
      'android/app/build.gradle.kts': [
        'com.google.firebase',
        'google-services.json',
      ],
      'android/common/build.gradle.kts': ['com.google.firebase'],
      '.github/workflows/build.yaml': [
        'GOOGLE_SERVICES_JSON',
        'google-services.json',
      ],
      'android/common/src/main/kotlin/com/follow/clashx/common/GlobalState.kt':
          [
        'FirebaseApp',
        'FirebaseCrashlytics',
      ],
      'android/service/src/main/aidl/com/follow/clashx/service/IRemoteInterface.aidl':
          [
        'setCrashlytics',
      ],
      'lib/models/config.dart': ['crashlytics'],
      'lib/views/application_setting.dart': ['crashlytics'],
      'arb/intl_en.arb': ['crashlytics'],
      'arb/intl_ja.arb': ['crashlytics'],
      'arb/intl_ru.arb': ['crashlytics'],
      'arb/intl_zh_CN.arb': ['crashlytics'],
    };

    for (final entry in forbiddenMarkers.entries) {
      final content = File(entry.key).readAsStringSync();
      for (final marker in entry.value) {
        expect(
          content,
          isNot(contains(marker)),
          reason: '`${entry.key}` must not restore `$marker`.',
        );
      }
    }
  });
}
