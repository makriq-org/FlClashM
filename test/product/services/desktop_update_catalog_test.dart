import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flclashx/product/android/android_update_bridge.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';
import 'package:flclashx/product/services/desktop_app_update_bridge.dart';
import 'package:flclashx/product/services/desktop_update_catalog.dart';
import 'package:flclashx/product/services/desktop_update_rollback.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SimpleKeyPair keyPair;
  late String publicKeyBase64;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    keyPair = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 1),
    );
    publicKeyBase64 = base64Encode((await keyPair.extractPublicKey()).bytes);
  });

  test('verifies Ed25519 before decoding the catalog', () async {
    final verifier = DesktopUpdateCatalogVerifier(
      publicKeyBase64: publicKeyBase64,
    );

    await expectLater(
      verifier.verifyAndDecode(
        catalogBytes: const [0xff],
        signatureBytes: List<int>.filled(64, 0),
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('signature'),
        ),
      ),
    );
  });

  test('accepts a signed catalog and rejects tampering', () async {
    final bytes = utf8.encode(jsonEncode(_catalogJson()));
    final signature = await Ed25519().sign(bytes, keyPair: keyPair);
    final verifier = DesktopUpdateCatalogVerifier(
      publicKeyBase64: publicKeyBase64,
    );

    final catalog = await verifier.verifyAndDecode(
      catalogBytes: bytes,
      signatureBytes: signature.bytes,
      expectedChannel: AppUpdateChannel.stable,
    );
    expect(catalog.catalogId, 'desktop-v1');
    expect(catalog.assets, hasLength(4));

    final tampered = [...bytes]..[bytes.length - 2] ^= 1;
    await expectLater(
      verifier.verifyAndDecode(
        catalogBytes: tampered,
        signatureBytes: signature.bytes,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );
  });

  test('selects every supported OS architecture and package kind exactly', () {
    final catalog = DesktopUpdateCatalog.fromJson(
      _catalogJson(),
      expectedChannel: AppUpdateChannel.stable,
    );

    for (final target in const [
      DesktopUpdateTarget(
        operatingSystem: DesktopUpdateOperatingSystem.linux,
        architecture: DesktopUpdateArchitecture.x64,
        packageKind: DesktopPackageKind.appImage,
      ),
      DesktopUpdateTarget(
        operatingSystem: DesktopUpdateOperatingSystem.windows,
        architecture: DesktopUpdateArchitecture.x64,
        packageKind: DesktopPackageKind.windowsInstaller,
      ),
      DesktopUpdateTarget(
        operatingSystem: DesktopUpdateOperatingSystem.macos,
        architecture: DesktopUpdateArchitecture.x64,
        packageKind: DesktopPackageKind.macosAppArchive,
      ),
      DesktopUpdateTarget(
        operatingSystem: DesktopUpdateOperatingSystem.macos,
        architecture: DesktopUpdateArchitecture.arm64,
        packageKind: DesktopPackageKind.macosAppArchive,
      ),
    ]) {
      expect(catalog.select(target).target.key, target.key);
    }
  });

  test('rejects duplicate targets path traversal and unsupported matrices', () {
    final duplicate = _catalogJson();
    final duplicateRelease =
        Map<String, dynamic>.from(duplicate['release'] as Map);
    final duplicateAssets = List<dynamic>.from(
      duplicateRelease['assets'] as List,
    )..add(Map<String, dynamic>.from(
        (duplicateRelease['assets'] as List).first as Map));
    duplicateRelease['assets'] = duplicateAssets;
    duplicate['release'] = duplicateRelease;
    expect(
      () => DesktopUpdateCatalog.fromJson(
        duplicate,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );

    final traversal = _catalogJson();
    _firstAsset(traversal)['name'] = '../FlClashM.AppImage';
    expect(
      () => DesktopUpdateCatalog.fromJson(
        traversal,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );

    final unsupported = _catalogJson();
    _firstAsset(unsupported)['arch'] = 'arm64';
    expect(
      () => DesktopUpdateCatalog.fromJson(
        unsupported,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );

    final runtimeOnly = _catalogJson();
    _firstAsset(runtimeOnly)['name'] = 'mihomo.tar.gz';
    expect(
      () => DesktopUpdateCatalog.fromJson(
        runtimeOnly,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );

    final insecureMirror = _catalogJson();
    _firstAsset(insecureMirror)['urls'] = ['http://mirror.example/app'];
    expect(
      () => DesktopUpdateCatalog.fromJson(
        insecureMirror,
        expectedChannel: AppUpdateChannel.stable,
      ),
      throwsFormatException,
    );
  });

  test('rollback maxima are separate by channel and catalog identity',
      () async {
    const guard = SharedPreferencesDesktopUpdateRollbackGuard();
    final current = _catalog(
      catalogId: 'desktop-v1',
      channel: AppUpdateChannel.stable,
      versionName: '2.0.0',
      versionCode: 200,
    );
    await guard.validateAndRecord(current);

    await expectLater(
      guard.validateAndRecord(
        _catalog(
          catalogId: 'desktop-v1',
          channel: AppUpdateChannel.stable,
          versionName: '1.9.0',
          versionCode: 199,
        ),
      ),
      throwsFormatException,
    );

    await guard.validateAndRecord(
      _catalog(
        catalogId: 'desktop-v1',
        channel: AppUpdateChannel.stable,
        versionName: '1.9.0',
        versionCode: 201,
      ),
    );
    await guard.validateAndRecord(
      _catalog(
        catalogId: 'desktop-v2',
        channel: AppUpdateChannel.stable,
        versionName: '1.0.0',
        versionCode: 1,
      ),
    );
    await guard.validateAndRecord(
      _catalog(
        catalogId: 'desktop-v1',
        channel: AppUpdateChannel.prerelease,
        versionName: '1.0.0-pre1',
        versionCode: 1,
      ),
    );
  });

  test('desktop uses its own signed pointer and versionCode update ordering',
      () async {
    final document = _catalogJson();
    final release = Map<String, dynamic>.from(document['release'] as Map)
      ..['tagName'] = 'v0.1.0'
      ..['versionName'] = '0.1.0'
      ..['versionCode'] = 101;
    document['release'] = release;
    final bytes = utf8.encode(jsonEncode(document));
    final signature = await Ed25519().sign(bytes, keyPair: keyPair);
    final client = _CatalogHttpClient({
      desktopUpdateCatalogUrl(AppUpdateChannel.stable): bytes,
      desktopUpdateCatalogSignatureUrl(AppUpdateChannel.stable):
          signature.bytes,
    });
    globalState.packageInfo = PackageInfo(
      appName: 'FlClashM',
      packageName: 'app.flclashm.client',
      version: '9.9.9',
      buildNumber: '100',
    );
    final bridge = DesktopAppUpdateBridge(
      environment: DesktopUpdateEnvironment.forOperatingSystem(
        'linux',
        architecture: DesktopUpdateArchitecture.x64,
      ),
      catalogVerifier: DesktopUpdateCatalogVerifier(
        publicKeyBase64: publicKeyBase64,
      ),
      desktopRollbackGuard: _RecordingRollbackGuard(),
      httpClient: client,
    );

    final update = await bridge.checkForAppUpdate(
      includePrerelease: false,
      skippedTagName: '',
    );

    expect(desktopUpdateCatalogUrl(AppUpdateChannel.stable),
        isNot(appUpdateManifestUrl(AppUpdateChannel.stable)));
    expect(update?.version, '0.1.0');
    expect(update?.versionCode, 101);
    expect(update?.assets.single.name, 'FlClashM.AppImage');
  });

  test('package-managed Linux refuses direct replacement', () async {
    final environment = DesktopUpdateEnvironment.forOperatingSystem(
      'linux',
      architecture: DesktopUpdateArchitecture.x64,
      packageManagedLinux: true,
    );
    final selector = DesktopAppUpdatePackageSelector(environment: environment);

    await expectLater(
      selector.select(
        release: _catalog(
          catalogId: 'desktop-v1',
          channel: AppUpdateChannel.stable,
          versionName: '1.2.3',
          versionCode: 2,
        ).toRelease(),
        platform: DesktopAppUpdateBridge(environment: environment),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

class _CatalogHttpClient implements AppUpdateHttpClient {
  _CatalogHttpClient(this.documents);

  final Map<String, List<int>> documents;

  @override
  Future<List<int>> readBytes(String url) async =>
      documents[url] ?? (throw StateError('missing document'));

  @override
  Future<List<dynamic>> readJsonList(String url) =>
      Future.error(UnimplementedError());

  @override
  Future<String?> readText(String url) => Future.value(null);

  @override
  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
    int? expectedLength,
  }) =>
      Future.error(UnimplementedError());
}

class _RecordingRollbackGuard implements DesktopUpdateRollbackGuard {
  @override
  Future<void> validateAndRecord(DesktopUpdateCatalog catalog) async {}
}

Map<String, dynamic> _catalogJson() => {
      'schemaVersion': 1,
      'catalogId': 'desktop-v1',
      'channel': 'stable',
      'release': {
        'tagName': 'v1.2.3',
        'versionName': '1.2.3',
        'versionCode': 2026081002,
        'publishedAt': '2026-08-10T12:00:00.000Z',
        'body': '- Desktop update',
        'htmlUrl': 'https://example.com/releases/v1.2.3',
        'assets': [
          _asset('linux', 'x86_64', 'appimage', 'FlClashM.AppImage'),
          _asset('windows', 'x86_64', 'windows-installer', 'FlClashM.exe'),
          _asset('macos', 'x86_64', 'macos-app-archive', 'FlClashM-x64.zip'),
          _asset('macos', 'arm64', 'macos-app-archive', 'FlClashM-arm64.zip'),
        ],
      },
    };

Map<String, dynamic> _asset(
  String os,
  String arch,
  String packageKind,
  String name,
) =>
    {
      'os': os,
      'arch': arch,
      'packageKind': packageKind,
      'name': name,
      'size': 4,
      'sha256': List.filled(64, 'a').join(),
      'urls': ['https://mirror.example/$name'],
    };

Map<String, dynamic> _firstAsset(Map<String, dynamic> document) {
  final release = Map<String, dynamic>.from(document['release'] as Map);
  final assets = List<dynamic>.from(release['assets'] as List);
  final asset = Map<String, dynamic>.from(assets.first as Map);
  assets[0] = asset;
  release['assets'] = assets;
  document['release'] = release;
  return asset;
}

DesktopUpdateCatalog _catalog({
  required String catalogId,
  required AppUpdateChannel channel,
  required String versionName,
  required int versionCode,
}) {
  final document = _catalogJson();
  document['catalogId'] = catalogId;
  document['channel'] = channel.wireName;
  final release = Map<String, dynamic>.from(document['release'] as Map)
    ..['tagName'] = 'v$versionName'
    ..['versionName'] = versionName
    ..['versionCode'] = versionCode;
  document['release'] = release;
  return DesktopUpdateCatalog.fromJson(document, expectedChannel: channel);
}
