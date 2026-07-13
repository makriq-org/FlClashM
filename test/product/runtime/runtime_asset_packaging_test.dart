import 'dart:io';

import 'package:flclashx/product/runtime/byedpi_release.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';
import 'package:flclashx/product/runtime/olcrtc_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter assets contain only runtime data required at runtime', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final runtimeAssets = pubspec
        .map((line) => line.trim())
        .where((line) => line.startsWith('- assets/runtimes/'))
        .toList();

    expect(runtimeAssets, const [
      '- assets/runtimes/byedpi/android/byebyeedpi-strategies.list',
    ]);
  });

  test('all pinned runtime ABIs are copied into Android native libraries', () {
    const expectedAbis = {'armeabi-v7a', 'arm64-v8a', 'x86_64'};
    expect(naiveProxyReleaseAssets.keys, expectedAbis);
    expect(byedpiReleaseAssets.keys, expectedAbis);
    expect(olcRtcReleaseAssets.keys, expectedAbis);

    final assets = <({String abi, String source, String target})>[
      for (final asset in naiveProxyReleaseAssets.values)
        (
          abi: asset.abi,
          source: asset.bundledAssetPath,
          target: naiveProxyAndroidNativeLibraryFileName,
        ),
      for (final asset in byedpiReleaseAssets.values)
        (
          abi: asset.abi,
          source: asset.bundledAssetPath,
          target: byedpiAndroidNativeLibraryFileName,
        ),
      for (final asset in olcRtcReleaseAssets.values)
        (
          abi: asset.abi,
          source: asset.bundledAssetPath,
          target: olcRtcAndroidNativeLibraryFileName,
        ),
    ];

    for (final asset in assets) {
      final source = File(asset.source);
      final target = File(
        'android/app/src/main/jniLibs/${asset.abi}/${asset.target}',
      );
      expect(source.existsSync(), isTrue, reason: asset.source);
      expect(target.existsSync(), isTrue, reason: target.path);
      expect(target.readAsBytesSync(), source.readAsBytesSync(),
          reason: target.path);
    }
  });

  test('runtime binary update entry points and swap paths are absent', () {
    final runtimeSources = Directory('lib/product/runtime')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    for (final removedContract in const [
      'applyPendingUpdate',
      'pendingBinarySwap',
      'MihomoUpdateBridge',
      'pendingVersionPath',
      'managedBinaryUpdateEnabled',
      '.pending',
      'bundled.pending.version',
    ]) {
      expect(runtimeSources, isNot(contains(removedContract)),
          reason: removedContract);
    }
  });
}
