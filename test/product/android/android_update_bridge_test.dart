import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flclashx/product/android/android_update_bridge.dart';
import 'package:flclashx/product/services/app_update_http.dart';
import 'package:flclashx/product/services/app_update_install_journal.dart';
import 'package:flclashx/product/services/app_update_manifest.dart';
import 'package:flclashx/product/services/app_update_mirrors.dart';
import 'package:flclashx/product/services/app_update_release.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeJournal implements AppUpdateInstallJournal {
  int? prepared;
  int clears = 0;

  @override
  Future<int?> readPreparedVersionCode() async => prepared;

  @override
  Future<void> recordPrepared(int versionCode) async => prepared = versionCode;

  @override
  Future<void> clear() async {
    prepared = null;
    clears++;
  }
}

class _FakeMirrors implements AppUpdateMirrorSource {
  _FakeMirrors([this.snapshot = AppUpdateMirrorSnapshot.empty]);

  AppUpdateMirrorSnapshot snapshot;
  int reads = 0;

  @override
  AppUpdateMirrorSnapshot read() {
    reads++;
    return snapshot;
  }
}

class _FakeHttpClient implements AppUpdateHttpClient {
  final documents = <String, AppUpdateHttpResponse>{};
  final downloads = <String, List<int>>{};
  final failedDownloads = <String>{};
  final requested = <String>[];
  void Function()? afterRequest;

  void respond(Uri url, List<int> body) {
    documents[url.toString()] = AppUpdateHttpResponse(
      statusCode: 200,
      body: body,
    );
  }

  void redirect(Uri from, Uri to) {
    documents[from.toString()] = AppUpdateHttpResponse(
      statusCode: 302,
      location: to,
    );
  }

  @override
  Future<AppUpdateHttpResponse> open(
    Uri url, {
    required int maxBytes,
    required Duration deadline,
  }) async {
    requested.add(url.toString());
    final response =
        documents[url.toString()] ??
        const AppUpdateHttpResponse(statusCode: 404);
    afterRequest?.call();
    return response;
  }

  @override
  Future<List<dynamic>> readJsonList(String url) async =>
      throw StateError('no GitHub answer in this test');

  @override
  Future<String?> readText(String url) async => null;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
    int? expectedLength,
  }) async {
    requested.add(url);
    if (failedDownloads.contains(url)) {
      throw StateError('mirror is down');
    }
    final bytes = downloads[url] ?? Uint8List(0);
    File(targetPath).writeAsBytesSync(bytes);
    onReceiveProgress?.call(bytes.length, bytes.length);
  }
}

class _TestBridge extends AndroidUpdateBridge {
  _TestBridge({
    required this.updateDirectory,
    required super.httpClient,
    required super.manifestVerifier,
    required super.mirrorSource,
    required super.installJournal,
  });

  final Directory updateDirectory;

  @override
  Future<String> getUpdateDirectoryPath() async {
    updateDirectory.createSync(recursive: true);
    return updateDirectory.path;
  }
}

void main() {
  late SimpleKeyPair keyPair;
  late String publicKeyBase64;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final algorithm = Ed25519();
    keyPair = await algorithm.newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 3),
    );
    publicKeyBase64 = base64Encode((await keyPair.extractPublicKey()).bytes);
    tempDir = Directory.systemTemp.createTempSync('app-update-bridge-');
    globalState.appEnv = 'stable';
    globalState.packageInfo = PackageInfo(
      appName: 'FlClashM',
      packageName: 'com.makriq.flclash',
      version: '1.0.0',
      buildNumber: '2026110101',
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Map<String, dynamic> manifestJson({
    String channel = 'stable',
    String tagName = 'v1.2.3',
    int versionCode = 2026111801,
    String publishedAt = '2026-11-18T10:00:00.000Z',
    List<String> urls = const ['https://example.com/app.apk'],
    String? minimumVersion,
    int? minimumVersionCode,
  }) => {
    'schemaVersion': 1,
    'channel': channel,
    'minVersion': ?minimumVersion,
    'minVersionCode': ?minimumVersionCode,
    'release': {
      'tagName': tagName,
      'versionName': tagName.substring(1),
      'versionCode': versionCode,
      'publishedAt': publishedAt,
      'body': '- изменение',
      'htmlUrl': 'https://sourceforge.net/projects/flclashm/files/v1.2.3/',
      'assets': [
        {
          'name': 'FlClashM-android-universal.apk',
          'size': 4,
          'sha256': 'a' * 64,
          'versionCode': versionCode,
          'urls': urls,
        },
      ],
    },
  };

  Future<({List<int> bytes, List<int> signature})> signManifest(
    Map<String, dynamic> document,
  ) async {
    final bytes = utf8.encode(jsonEncode(document));
    final signature = await Ed25519().sign(bytes, keyPair: keyPair);
    return (bytes: bytes, signature: signature.bytes);
  }

  Future<void> publish(
    _FakeHttpClient client,
    Uri manifestUrl,
    Map<String, dynamic> document,
  ) async {
    final signed = await signManifest(document);
    client
      ..respond(manifestUrl, signed.bytes)
      ..respond(appUpdateSignatureUriOf(manifestUrl), signed.signature);
  }

  AndroidUpdateBridge buildBridge(
    _FakeHttpClient client, {
    _FakeMirrors? mirrors,
    _FakeJournal? journal,
    DateTime? clock,
  }) => AndroidUpdateBridge(
    httpClient: client,
    manifestVerifier: AppUpdateManifestVerifier(
      publicKeyBase64: publicKeyBase64,
    ),
    mirrorSource: mirrors ?? _FakeMirrors(),
    installJournal: journal ?? _FakeJournal(),
    now: clock == null ? _utcNow : () => clock,
  );

  _TestBridge buildDownloadBridge(
    _FakeHttpClient client, {
    _FakeJournal? journal,
  }) => _TestBridge(
    updateDirectory: tempDir,
    httpClient: client,
    manifestVerifier: AppUpdateManifestVerifier(
      publicKeyBase64: publicKeyBase64,
    ),
    mirrorSource: _FakeMirrors(),
    installJournal: journal ?? _FakeJournal(),
  );

  final officialStable = Uri.parse(appUpdateManifestUrl(AppUpdateChannel.stable));
  final mirrorStable = Uri.parse('https://mirror.example/update/stable.json');

  group('checkForAppUpdate', () {
    test('reads the official signed catalog first', () async {
      final client = _FakeHttpClient();
      await publish(client, officialStable, manifestJson());
      final bridge = buildBridge(client);

      final release = await bridge.checkForAppUpdate(
        includePrerelease: false,
        skippedTagName: '',
      );

      expect(release?.tagName, 'v1.2.3');
      expect(release?.minimumVersionCode, isNull);
      expect(client.requested.first, officialStable.toString());
    });

    test('falls back to the profile mirror when the official one is down',
        () async {
      final client = _FakeHttpClient();
      await publish(client, mirrorStable, manifestJson());
      final mirrors = _FakeMirrors(
        AppUpdateMirrorSnapshot.fromHeaders(
          profileId: 'profile-1',
          headers: const {
            appUpdateMirrorHeaderStable: 'https://mirror.example/update',
          },
        ),
      );
      final bridge = buildBridge(client, mirrors: mirrors);

      final release = await bridge.checkForAppUpdate(
        includePrerelease: false,
        skippedTagName: '',
      );

      expect(release?.tagName, 'v1.2.3');
      expect(client.requested, contains(mirrorStable.toString()));
    });

    test('a mirror of the other channel is refused by the signature check',
        () async {
      final client = _FakeHttpClient();
      await publish(
        client,
        mirrorStable,
        manifestJson(channel: 'pre', tagName: 'v1.2.3-pre1'),
      );
      final mirrors = _FakeMirrors(
        AppUpdateMirrorSnapshot.fromHeaders(
          profileId: 'profile-1',
          headers: const {
            appUpdateMirrorHeaderStable: 'https://mirror.example/update',
          },
        ),
      );
      final bridge = buildBridge(client, mirrors: mirrors);

      final release = await bridge.checkForAppUpdate(
        includePrerelease: false,
        skippedTagName: '',
      );

      expect(release, isNull);
    });

    test('a mirror answer signed by another key is refused', () async {
      final client = _FakeHttpClient();
      final otherKey = await Ed25519().newKeyPairFromSeed(
        List<int>.generate(32, (index) => index + 9),
      );
      final document = manifestJson();
      final bytes = utf8.encode(jsonEncode(document));
      final signature = await Ed25519().sign(bytes, keyPair: otherKey);
      client
        ..respond(mirrorStable, bytes)
        ..respond(appUpdateSignatureUriOf(mirrorStable), signature.bytes);
      final mirrors = _FakeMirrors(
        AppUpdateMirrorSnapshot.fromHeaders(
          profileId: 'profile-1',
          headers: const {
            appUpdateMirrorHeaderStable: 'https://mirror.example/update',
          },
        ),
      );
      final bridge = buildBridge(client, mirrors: mirrors);

      expect(
        await bridge.checkForAppUpdate(
          includePrerelease: false,
          skippedTagName: '',
        ),
        isNull,
      );
    });

    test('follows a redirect only after checking the next address', () async {
      final client = _FakeHttpClient();
      final cdn = Uri.parse('https://cdn.example/update/stable.json');
      client
        ..redirect(officialStable, cdn)
        ..redirect(
          appUpdateSignatureUriOf(officialStable),
          appUpdateSignatureUriOf(cdn),
        );
      await publish(client, cdn, manifestJson());
      final bridge = buildBridge(client);

      final release = await bridge.checkForAppUpdate(
        includePrerelease: false,
        skippedTagName: '',
      );

      expect(release?.tagName, 'v1.2.3');
      expect(client.requested, contains(cdn.toString()));
    });

    test('refuses a redirect that leaves HTTPS', () async {
      final client = _FakeHttpClient()
        ..redirect(officialStable, Uri.parse('http://cdn.example/s.json'));
      final bridge = buildBridge(client);

      expect(
        await bridge.checkForAppUpdate(
          includePrerelease: false,
          skippedTagName: '',
        ),
        isNull,
      );
    });

    test('an answer of a previous profile does not replace the decision',
        () async {
      final client = _FakeHttpClient();
      await publish(client, officialStable, manifestJson());
      final mirrors = _FakeMirrors(
        AppUpdateMirrorSnapshot.fromHeaders(
          profileId: 'profile-1',
          headers: const {
            appUpdateMirrorHeaderStable: 'https://mirror.example/update',
          },
        ),
      );
      final bridge = buildBridge(client, mirrors: mirrors);
      // Пока шёл запрос, пользователь переключил профиль.
      client.afterRequest = () {
        mirrors.snapshot = AppUpdateMirrorSnapshot.fromHeaders(
          profileId: 'profile-2',
          headers: const {
            appUpdateMirrorHeaderStable: 'https://other.example/update',
          },
        );
      };

      final release = await bridge.checkForAppUpdate(
        includePrerelease: false,
        skippedTagName: '',
      );

      expect(release, isNull);
    });

    test('a skipped tag hides the update until it becomes required', () async {
      final client = _FakeHttpClient();
      await publish(
        client,
        officialStable,
        manifestJson(minimumVersionCode: 2026111801),
      );
      final bridge = buildBridge(client);

      expect(
        await bridge.checkForAppUpdate(
          includePrerelease: false,
          skippedTagName: 'v1.2.3',
        ),
        isNotNull,
      );

      final optional = _FakeHttpClient();
      await publish(optional, officialStable, manifestJson());
      expect(
        await buildBridge(optional).checkForAppUpdate(
          includePrerelease: false,
          skippedTagName: 'v1.2.3',
        ),
        isNull,
      );
    });

    test('keeps the minimum version of a fresh catalog only', () async {
      final client = _FakeHttpClient();
      await publish(
        client,
        officialStable,
        manifestJson(minimumVersionCode: 2026111801),
      );
      final stale = await buildBridge(
        client,
        clock: DateTime.utc(2027, 12, 31),
      ).checkForAppUpdate(includePrerelease: false, skippedTagName: '');

      expect(stale?.minimumVersionCode, isNull);
      expect(stale?.tagName, 'v1.2.3');
    });

    test('rejects a replayed older catalog', () async {
      final client = _FakeHttpClient();
      await publish(client, officialStable, manifestJson());
      final bridge = buildBridge(client);
      expect(
        await bridge.checkForAppUpdate(
          includePrerelease: false,
          skippedTagName: '',
        ),
        isNotNull,
      );

      final replayed = _FakeHttpClient();
      await publish(
        replayed,
        officialStable,
        manifestJson(
          tagName: 'v1.0.0',
          versionCode: 2026010101,
          publishedAt: '2026-01-01T10:00:00.000Z',
        ),
      );
      final second = buildBridge(replayed);
      expect(
        await second.checkForAppUpdate(
          includePrerelease: false,
          skippedTagName: '',
        ),
        isNull,
      );
    });
  });

  group('downloadReleaseAsset', () {
    ReleaseAsset asset(List<String> urls, {int size = 4}) => ReleaseAsset(
      name: 'FlClashM-android-universal.apk',
      browserDownloadUrl: urls.first,
      downloadUrls: urls,
      size: size,
    );

    test('tries mirrors in order', () async {
      final client = _FakeHttpClient()
        ..downloads['https://github.example/app.apk'] = [1, 2, 3, 4]
        ..failedDownloads.add('https://sourceforge.example/app.apk');
      final bridge = buildBridge(client);
      final target = '${tempDir.path}/app.apk.part';

      final digest = await bridge.downloadReleaseAsset(
        asset(const [
          'https://sourceforge.example/app.apk',
          'https://github.example/app.apk',
        ]),
        target,
        expectedSha256: _sha256Hex([1, 2, 3, 4]),
      );

      expect(digest, _sha256Hex([1, 2, 3, 4]));
      expect(File(target).readAsBytesSync(), [1, 2, 3, 4]);
      expect(client.requested, [
        'https://sourceforge.example/app.apk',
        'https://github.example/app.apk',
      ]);
    });

    test('rejects a mirror that answers with another size', () async {
      final client = _FakeHttpClient()
        ..downloads['https://github.example/app.apk'] = [1, 2, 3, 4];
      final bridge = buildBridge(client);

      await expectLater(
        bridge.downloadReleaseAsset(
          asset(const [
            'https://sourceforge.example/app.apk',
            'https://github.example/app.apk',
          ], size: 5),
          '${tempDir.path}/app.apk.part',
          expectedSha256: _sha256Hex([1, 2, 3, 4]),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('pruneInstalledUpdates', () {
    test('keeps the APK while the installation is not confirmed', () async {
      final journal = _FakeJournal()..prepared = 2026111801;
      final apk = File('${tempDir.path}/FlClashM-android-universal.apk')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final bridge = buildDownloadBridge(_FakeHttpClient(), journal: journal);

      await bridge.pruneInstalledUpdates();

      expect(apk.existsSync(), isTrue);
      expect(journal.clears, 0);
    });

    test('removes downloaded APKs after a confirmed update', () async {
      final journal = _FakeJournal()..prepared = 2026110101;
      final apk = File('${tempDir.path}/FlClashM-android-universal.apk')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final bridge = buildDownloadBridge(_FakeHttpClient(), journal: journal);

      await bridge.pruneInstalledUpdates();

      expect(apk.existsSync(), isFalse);
      expect(journal.clears, 1);
    });
  });
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

DateTime _utcNow() => DateTime.now().toUtc();
