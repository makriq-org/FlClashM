import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/product/runtime/built_in_proxy_registry.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/stormdns_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled release stamp and Android ABI assets match the pin', () {
    final expectedStamp = <String>[
      stormDnsPinnedReleaseTag,
      stormDnsSourceRepository,
      stormDnsPinnedGoVersion,
      'ndk-$stormDnsPinnedNdkVersion',
      ...stormDnsReleaseAssets.values.map(
        (asset) => '${asset.abi}:${asset.goArch}:${asset.goArm ?? ''}',
      ),
    ].join('\n');

    expect(
      File('assets/runtimes/stormdns/android/release.txt')
          .readAsStringSync()
          .trim(),
      expectedStamp,
    );
    expect(stormDnsReleaseAssets.keys, {
      'armeabi-v7a',
      'arm64-v8a',
      'x86_64',
    });
    for (final asset in stormDnsReleaseAssets.values) {
      final bytes = File(asset.bundledAssetPath).readAsBytesSync();
      expect(bytes.length, greaterThan(4), reason: asset.abi);
      expect(bytes.take(4), [0x7f, 0x45, 0x4c, 0x46], reason: asset.abi);
      expect(sha256.convert(bytes).toString(), asset.sha256, reason: asset.abi);
    }
  });

  test('the source commit is pinned, not a moving reference', () {
    expect(stormDnsPinnedCommit, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(stormDnsPinnedReleaseTag, 'git-$stormDnsPinnedCommit');
  });

  test('the Go toolchain matches the other Go runtimes of the project', () {
    final setupSource = File('setup.dart').readAsStringSync();
    expect(setupSource, contains('_requireGoVersion(stormDnsPinnedGoVersion)'));
    expect(setupSource, contains("'./cmd/client',"));
    expect(
      setupSource,
      contains(r'stormdns ${asset.abi} digest mismatch: '),
      reason: 'a build that drifts from the pin must fail, not be published',
    );
  });

  test('setup packages every ABI as an Android native library', () {
    final setupSource = File('setup.dart').readAsStringSync();
    expect(
      setupSource,
      contains('for (final asset in stormDnsReleaseAssets.values)'),
    );
    expect(
      setupSource,
      contains('fileName: stormDnsAndroidNativeLibraryFileName'),
    );
    expect(stormDnsAndroidNativeLibraryFileName, startsWith('libflclashm_'));
  });

  test('the binary is never downloaded or swapped at runtime', () {
    final runtimeSources = Directory('lib/product/runtime')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('stormdns'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    for (final forbidden in const [
      'HttpClient',
      'download',
      '.pending',
      'applyPendingUpdate',
    ]) {
      expect(runtimeSources, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('the MIT notice is kept next to the runtime metadata', () {
    final licence =
        File('assets/runtimes/stormdns/android/LICENSE').readAsStringSync();
    expect(licence, contains('MIT License'));
    expect(licence, contains('StormDNS'));
  });

  test('the descriptor matches the agreed runtime contract', () {
    final descriptor =
        builtInProxyRegistry.descriptorFor(BuiltInProxyType.stormdns);
    expect(descriptor.listenPortRangeStart, 36200);
    expect(descriptor.supportsUdp, isFalse);
    expect(descriptor.defaultUdp, isFalse);
    expect(descriptor.supportsActivation, isTrue);
    expect(descriptor.protocol, BuiltInProxyProtocol.socks5);
    expect(descriptor.availability.isSupported, isTrue);
  });

  test('the build workflow uploads the runtime assets', () {
    expect(
      File('.github/workflows/build.yaml').readAsStringSync(),
      contains('assets/runtimes/stormdns'),
    );
  });
}
