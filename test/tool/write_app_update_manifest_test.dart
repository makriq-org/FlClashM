import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/write_app_update_manifest.dart';

void main() {
  test('builds and signs a SourceForge-first Android update manifest',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('update-manifest-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final dist = Directory('${tempDir.path}/dist')..createSync();
    File('${dist.path}/FlClashM-android-arm64-v8a.apk')
        .writeAsBytesSync([1, 2, 3]);
    File('${dist.path}/FlClashM-android-release.aab')
        .writeAsBytesSync([4, 5, 6]);
    File('${dist.path}/FlClashM-android-release-metadata.json')
        .writeAsStringSync(jsonEncode({
      'versionCode': 2026073401,
      'apkVersionCodes': {
        'FlClashM-android-arm64-v8a.apk': 2026073401,
      },
    }));
    final notes = File('${tempDir.path}/release.md')
      ..writeAsStringSync('## Что изменилось\n\n- Проверка\n');
    final options = ManifestOptions(
      distPath: dist.path,
      outputPath: '${dist.path}/stable.json',
      releaseNotesPath: notes.path,
      tagName: 'v0.10.5',
      githubRepository: 'makriq-org/FlClashM',
      channel: AppUpdateChannel.stable,
      publishedAt: DateTime.utc(2026, 7, 14, 10),
    );

    final manifest = await buildAppUpdateManifest(options);
    final bytes = utf8.encode(jsonEncode(manifest.toJson()));
    final seed = List<int>.generate(32, (index) => index + 1);
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final signature = await signAppUpdateManifest(
      bytes,
      signingKeyBase64: base64Encode(seed),
      expectedPublicKeyBase64: base64Encode(publicKey.bytes),
    );
    final verified = await AppUpdateManifestVerifier(
      publicKeyBase64: base64Encode(publicKey.bytes),
    ).verifyAndDecode(
      manifestBytes: bytes,
      signatureBytes: signature,
      expectedChannel: AppUpdateChannel.stable,
    );

    expect(verified.assets, hasLength(1));
    expect(verified.versionCode, 2026073401);
    expect(verified.assets.single.versionCode, 2026073401);
    expect(verified.assets.single.name, 'FlClashM-android-arm64-v8a.apk');
    expect(
      verified.assets.single.urls.first,
      'https://sourceforge.net/projects/flclashm/files/releases/v0.10.5/'
      'FlClashM-android-arm64-v8a.apk/download',
    );
    expect(
      verified.assets.single.urls.last,
      'https://github.com/makriq-org/FlClashM/releases/download/v0.10.5/'
      'FlClashM-android-arm64-v8a.apk',
    );
  });

  test('rejects a release tag that does not match the channel', () {
    expect(
      () => ManifestOptions.parse([
        '--dist=dist',
        '--out=dist/stable.json',
        '--release-notes=release.md',
        '--tag=v0.10.5-pre1',
        '--github-repository=makriq-org/FlClashM',
        '--channel=stable',
        '--published-at=2026-07-14T10:00:00.000Z',
        '--version-code=2026073401',
      ]),
      throwsArgumentError,
    );
  });

  test('allows a verified APK version code override for manifest repair',
      () async {
    final tempDir =
        Directory.systemTemp.createTempSync('update-manifest-code-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final dist = Directory('${tempDir.path}/dist')..createSync();
    File('${dist.path}/FlClashM-android-arm64-v8a.apk')
        .writeAsBytesSync([1, 2, 3]);
    final notes = File('${tempDir.path}/release.md')
      ..writeAsStringSync('- Проверка\n');
    final options = ManifestOptions(
      distPath: dist.path,
      outputPath: '${dist.path}/stable.json',
      releaseNotesPath: notes.path,
      tagName: 'v0.10.5',
      githubRepository: 'makriq-org/FlClashM',
      channel: AppUpdateChannel.stable,
      publishedAt: DateTime.utc(2026, 8, 24),
      versionCode: 2026085802,
    );

    final manifest = await buildAppUpdateManifest(options);

    expect(manifest.versionCode, 2026085802);
  });

  test('rejects a signing key that does not match the embedded public key',
      () async {
    final signingSeed = List<int>.generate(32, (index) => index);
    final otherKeyPair = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 1),
    );
    final otherPublicKey = await otherKeyPair.extractPublicKey();

    await expectLater(
      signAppUpdateManifest(
        utf8.encode('{}'),
        signingKeyBase64: base64Encode(signingSeed),
        expectedPublicKeyBase64: base64Encode(otherPublicKey.bytes),
      ),
      throwsFormatException,
    );
  });

  test('starts under the standalone Dart VM used by the release workflow',
      () async {
    final versionName = RegExp(
      r'^version:\s*([^+]+)\+',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;
    final tempDir = Directory.systemTemp.createTempSync('update-manifest-vm-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final dist = Directory('${tempDir.path}/dist')..createSync();
    File('${dist.path}/FlClashM-android-arm64-v8a.apk')
        .writeAsBytesSync([1, 2, 3]);
    final notes = File('${tempDir.path}/release.md')
      ..writeAsStringSync('- Проверка запуска\n');
    final result = await Process.run(
      'dart',
      [
        'tool/write_app_update_manifest.dart',
        '--dist=${dist.path}',
        '--out=${tempDir.path}/pre.json',
        '--release-notes=${notes.path}',
        '--tag=v$versionName',
        '--github-repository=makriq-org/FlClashM',
        '--channel=${versionName.contains('-') ? 'pre' : 'stable'}',
        '--published-at=2026-07-14T10:00:00.000Z',
        '--version-code=2026073401',
      ],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'APP_UPDATE_SIGNING_KEY': base64Encode(List<int>.filled(32, 1)),
      },
    );
    final output = '${result.stdout}\n${result.stderr}';

    expect(result.exitCode, isNot(0));
    expect(output, contains('does not match the embedded public key'));
    expect(output, isNot(contains("Dart library 'dart:ui' is not available")));
  });
}
