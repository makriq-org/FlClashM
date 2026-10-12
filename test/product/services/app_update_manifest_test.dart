import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';
import 'package:flclashx/product/services/app_update_manifest_release.dart';
import 'package:flclashx/product/services/app_update_manifest_rollback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<int> manifestBytes;
  late List<int> signatureBytes;
  late String publicKeyBase64;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manifestBytes = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'channel': 'stable',
        'release': {
          'tagName': 'v1.2.3',
          'versionName': '1.2.3',
          'versionCode': 2026073401,
          'publishedAt': '2026-07-14T10:00:00.000Z',
          'body': '- Исправлено обновление',
          'htmlUrl':
              'https://sourceforge.net/projects/flclashm/files/releases/v1.2.3/',
          'assets': [
            {
              'name': 'FlClashM-android-arm64-v8a.apk',
              'size': 123,
              'sha256': List.filled(64, 'a').join(),
              'versionCode': 2026073401,
              'urls': [
                Uri.https(
                  'sourceforge.net',
                  '/projects/flclashm/files/releases/v1.2.3/'
                      'FlClashM-android-arm64-v8a.apk/download',
                ).toString(),
                Uri.https(
                  'github.com',
                  '/makriq-org/FlClashM/releases/download/v1.2.3/'
                      'FlClashM-android-arm64-v8a.apk',
                ).toString(),
              ],
            },
          ],
        },
      }),
    );
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(
      List<int>.generate(32, (index) => index),
    );
    final publicKey = await keyPair.extractPublicKey();
    publicKeyBase64 = base64Encode(publicKey.bytes);
    signatureBytes = (await algorithm.sign(
      manifestBytes,
      keyPair: keyPair,
    ))
        .bytes;
  });

  test('accepts signed manifest and keeps ordered download mirrors', () async {
    final verifier = AppUpdateManifestVerifier(
      publicKeyBase64: publicKeyBase64,
    );

    final manifest = await verifier.verifyAndDecode(
      manifestBytes: manifestBytes,
      signatureBytes: signatureBytes,
      expectedChannel: AppUpdateChannel.stable,
    );

    final release = manifest.toRelease();
    expect(release.tagName, 'v1.2.3');
    expect(release.prerelease, isFalse);
    expect(
      release.assets.single.sha256Digest,
      List.filled(64, 'a').join(),
    );
    expect(release.assets.single.downloadUrls, hasLength(2));
    expect(release.assets.single.versionCode, 2026073401);
    expect(
      release.assets.single.downloadUrls.first,
      startsWith('https://sourceforge.net/'),
    );
    expect(
      release.assets.single.downloadUrls.last,
      startsWith('https://github.com/'),
    );
  });

  test('rejects manifest modified after signing', () async {
    final verifier = AppUpdateManifestVerifier(
      publicKeyBase64: publicKeyBase64,
    );
    final tampered = [...manifestBytes]..[manifestBytes.length - 1] ^= 1;

    await expectLater(
      verifier.verifyAndDecode(
        manifestBytes: tampered,
        signatureBytes: signatureBytes,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );
  });

  test('rejects a valid document from another channel', () async {
    final verifier = AppUpdateManifestVerifier(
      publicKeyBase64: publicKeyBase64,
    );

    await expectLater(
      verifier.verifyAndDecode(
        manifestBytes: manifestBytes,
        signatureBytes: signatureBytes,
        expectedChannel: AppUpdateChannel.prerelease,
      ),
      throwsFormatException,
    );
  });

  test('rejects a prerelease tag in the stable channel', () {
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    final document = Map<String, dynamic>.from(decoded as Map);
    final release = Map<String, dynamic>.from(document['release'] as Map)
      ..['tagName'] = 'v1.2.3-pre1'
      ..['versionName'] = '1.2.3-pre1';
    document['release'] = release;

    expect(
      () => AppUpdateManifest.fromJson(
        document,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );
  });

  test('rejects replay of an older signed manifest state', () async {
    const guard = SharedPreferencesAppUpdateManifestRollbackGuard();
    const asset = AppUpdateManifestAsset(
      name: 'FlClashM-android-arm64-v8a.apk',
      size: 123,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      urls: ['https://example.com/app.apk'],
    );
    final current = AppUpdateManifest(
      channel: AppUpdateChannel.stable,
      tagName: 'v1.2.3',
      versionName: '1.2.3',
      versionCode: 2026071401,
      publishedAt: DateTime.utc(2026, 7, 14, 10),
      body: '',
      htmlUrl: 'https://example.com/v1.2.3',
      assets: const [asset],
    );
    final replayed = AppUpdateManifest(
      channel: AppUpdateChannel.stable,
      tagName: 'v1.2.2',
      versionName: '1.2.2',
      versionCode: 2026071301,
      publishedAt: DateTime.utc(2026, 7, 13, 10),
      body: '',
      htmlUrl: 'https://example.com/v1.2.2',
      assets: const [asset],
    );

    await guard.validateAndRecord(current);

    await expectLater(
      guard.validateAndRecord(replayed),
      throwsFormatException,
    );
  });

  test('rejects an older publication with the same version code', () async {
    const guard = SharedPreferencesAppUpdateManifestRollbackGuard();
    const asset = AppUpdateManifestAsset(
      name: 'FlClashM-android-arm64-v8a.apk',
      size: 123,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      urls: ['https://example.com/app.apk'],
    );
    AppUpdateManifest manifest(DateTime publishedAt) => AppUpdateManifest(
          channel: AppUpdateChannel.prerelease,
          tagName: 'v1.2.3-pre1',
          versionName: '1.2.3-pre1',
          versionCode: 2026071401,
          publishedAt: publishedAt,
          body: '',
          htmlUrl: 'https://example.com/v1.2.3-pre1',
          assets: const [asset],
        );

    await guard.validateAndRecord(manifest(DateTime.utc(2026, 7, 14, 11)));

    await expectLater(
      guard.validateAndRecord(manifest(DateTime.utc(2026, 7, 14, 10))),
      throwsFormatException,
    );
  });
}
