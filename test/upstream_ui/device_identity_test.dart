import 'dart:io';

import 'package:flclashx/common/package.dart';
import 'package:flclashx/common/system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('a leanback or television feature marks the device as a TV', () {
    expect(isTelevision(['android.software.leanback']), isTrue);
    expect(isTelevision(['android.hardware.type.television']), isTrue);
    expect(isTelevision(const []), isFalse);
    expect(isTelevision(['android.hardware.touchscreen']), isFalse);
  });

  test('a TV names itself androidtv, which still reads as android', () {
    final info = PackageInfo(
      appName: 'FlClashM',
      packageName: 'com.makriq.flclash',
      version: '1.0.0',
      buildNumber: '1',
    );

    final tv = info.uaWith('v1.19.34', tv: true);
    expect(tv, endsWith('Platform/androidtv'));
    expect(tv, contains('Platform/android'));
    expect(tv, contains('core/v1.19.34'));
    expect(
      info.uaWith('v1.19.34'),
      endsWith('Platform/${Platform.operatingSystem}'),
    );
  });
}
