import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';
import 'package:flclashx/product/services/desktop_update_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/write_app_update_manifest.dart' show signAppUpdateManifest;
import '../../tool/write_desktop_update_catalog.dart';

void main() {
  test('publishes a signed Windows x64 catalog for the verified installer', () async {
    final directory = Directory.systemTemp.createTempSync('desktop-catalog-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dist = Directory('${directory.path}/dist')..createSync();
    final installer = File('${dist.path}/FlClashM-windows-x64-setup.exe')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final notes = File('${directory.path}/release.md')
      ..writeAsStringSync('## Изменения\n\n- Поддержка Windows\n');
    final catalog = await buildDesktopUpdateCatalog(
      DesktopCatalogOptions(
        dist: dist.path,
        output: '${directory.path}/pre.json',
        releaseNotes: notes.path,
        tag: 'v0.11.0-pre1',
        repository: 'makriq-org/FlClashM',
        channel: AppUpdateChannel.prerelease,
        publishedAt: DateTime.utc(2026, 9, 25),
      ),
    );
    final bytes = utf8.encode(jsonEncode(catalog));
    final seed = List<int>.generate(32, (index) => index + 1);
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await pair.extractPublicKey();
    final signature = await signAppUpdateManifest(
      bytes,
      signingKeyBase64: base64Encode(seed),
      expectedPublicKeyBase64: base64Encode(publicKey.bytes),
    );
    final verified = await DesktopUpdateCatalogVerifier(
      publicKeyBase64: base64Encode(publicKey.bytes),
    ).verifyAndDecode(
      catalogBytes: bytes,
      signatureBytes: signature,
      expectedChannel: AppUpdateChannel.prerelease,
    );
    final selected = verified.select(
      const DesktopUpdateTarget(
        operatingSystem: DesktopUpdateOperatingSystem.windows,
        architecture: DesktopUpdateArchitecture.x64,
        packageKind: DesktopPackageKind.windowsInstaller,
      ),
    );

    expect(selected.name, 'FlClashM-windows-x64-setup.exe');
    expect(selected.sha256, sha256.convert(installer.readAsBytesSync()).toString());
    expect(selected.size, 4);
    expect(selected.urls.first, startsWith('https://sourceforge.net/'));
    expect(selected.urls.last, startsWith('https://github.com/'));
  });
}
