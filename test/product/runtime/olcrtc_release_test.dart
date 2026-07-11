import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/product/runtime/olcrtc_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled release stamp and Android ABI assets match the pin', () {
    final expectedStamp = <String>[
      olcRtcPinnedReleaseTag,
      olcRtcSourceRepository,
      olcRtcPinnedGoVersion,
      'ndk-$olcRtcPinnedNdkVersion',
      ...olcRtcReleaseAssets.values.map(
        (asset) => '${asset.abi}:${asset.goArch}:${asset.goArm ?? ''}',
      ),
    ].join('\n');

    expect(
      File('assets/runtimes/olcrtc/android/release.txt')
          .readAsStringSync()
          .trim(),
      expectedStamp,
    );
    expect(olcRtcReleaseAssets.keys, {
      'armeabi-v7a',
      'arm64-v8a',
      'x86_64',
    });
    for (final asset in olcRtcReleaseAssets.values) {
      final bytes = File(asset.bundledAssetPath).readAsBytesSync();
      expect(bytes.length, greaterThan(4), reason: asset.abi);
      expect(bytes.take(4), [0x7f, 0x45, 0x4c, 0x46], reason: asset.abi);
      expect(sha256.convert(bytes).toString(), asset.sha256, reason: asset.abi);
    }
  });
}
