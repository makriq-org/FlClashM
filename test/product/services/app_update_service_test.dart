import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/product/android/android_update_bridge.dart';
import 'package:flclashx/product/services/app_update_release.dart';
import 'package:flclashx/product/services/app_update_service.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUpdateBridge implements AppUpdatePlatformBridge {
  _FakeUpdateBridge({
    required this.updateDirectoryPath,
    this.checkResult,
    this.promptResult,
    this.installResult = true,
    this.openReleasePageOnError = false,
  });

  final AppRelease? checkResult;
  final bool? promptResult;
  final List<String> supportedAbis = const ['arm64-v8a'];
  final bool installResult;
  final bool openReleasePageOnError;
  final String updateDirectoryPath;

  int checkCalls = 0;
  int errorCalls = 0;
  int installCalls = 0;
  int prepareCalls = 0;
  String? lastInstallPath;
  AppRelease? promptedRelease;
  List<String>? promptedSubmits;
  String? installErrorMessage;
  String? installErrorReleaseUrl;
  final downloadedAssets = <String>[];
  final openedReleaseUrls = <String>[];
  final remoteTexts = <String, String?>{};
  final assetBytesByUrl = <String, List<int>>{};

  @override
  String get latestReleaseUrl => 'https://example.com/releases/latest';

  @override
  Future<AppRelease?> checkForAppUpdate() async {
    checkCalls++;
    return checkResult;
  }

  @override
  Future<bool?> promptForUpdateDownload({
    required AppRelease release,
    required List<String> submits,
  }) async {
    promptedRelease = release;
    promptedSubmits = submits;
    return promptResult;
  }

  @override
  Future<void> showUpdateCheckError() async {
    errorCalls++;
  }

  @override
  Future<void> showUpdateInstallError({
    required String message,
    required String releaseUrl,
  }) async {
    installErrorMessage = message;
    installErrorReleaseUrl = releaseUrl;
    if (openReleasePageOnError) {
      await openReleasePage(releaseUrl);
    }
  }

  @override
  Future<List<String>> readSupportedAbis() async => supportedAbis;

  @override
  Future<String?> readRemoteText(String url) async => remoteTexts[url];

  @override
  Future<void> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    downloadedAssets.add(asset.browserDownloadUrl);
    final bytes = assetBytesByUrl[asset.browserDownloadUrl];
    if (bytes == null) {
      throw StateError(
          'Missing fake asset payload for ${asset.browserDownloadUrl}');
    }
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    onReceiveProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<String> getUpdateDirectoryPath() async => updateDirectoryPath;

  @override
  Future<void> prepareInstallHandoff() async {
    prepareCalls++;
  }

  @override
  Future<bool> openReleasePage(String url) async {
    openedReleaseUrls.add(url);
    return true;
  }

  @override
  Future<bool> installPackage(String path) async {
    installCalls++;
    lastInstallPath = path;
    return installResult;
  }
}

void main() {
  group('AppUpdateService', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('app-update-service-');
      globalState.isPre = false;
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('skips automatic checks when disabled or pre-release', () async {
      final bridge = _FakeUpdateBridge(updateDirectoryPath: tempDir.path);
      final service = AppUpdateService(platform: bridge);

      await service.autoCheck(enabled: false);
      globalState.isPre = true;
      await service.autoCheck(enabled: true);

      expect(bridge.checkCalls, 0);
      expect(bridge.errorCalls, 0);
    });

    test('downloads verifies and installs a compatible Android APK', () async {
      final bytes = utf8.encode('arm64-release');
      final digest = sha256.convert(bytes).toString();
      final release = AppRelease(
        tagName: 'v1.2.3',
        body: '- first change\n- second change',
        htmlUrl: 'https://example.com/releases/v1.2.3',
        assets: [
          ReleaseAsset(
            name: 'FlClashM-1.2.3-android-arm64-v8a.apk',
            browserDownloadUrl: 'https://example.com/arm64.apk',
            size: bytes.length,
            digest: 'sha256:$digest',
          ),
        ],
        prerelease: false,
        draft: false,
      );
      final bridge = _FakeUpdateBridge(
        updateDirectoryPath: tempDir.path,
        checkResult: release,
        promptResult: true,
      )..assetBytesByUrl['https://example.com/arm64.apk'] = bytes;
      final service = AppUpdateService(platform: bridge);
      final runnerTitles = <String?>[];

      Future<T?> runTask<T>(Future<T> Function() task, {String? title}) async {
        runnerTitles.add(title);
        return task();
      }

      await service.manualCheck(
        runTask: runTask,
        loadingTitle: 'Check update',
      );

      final installedFile = File(
        '${tempDir.path}/FlClashM-1.2.3-android-arm64-v8a.apk',
      );
      expect(bridge.checkCalls, 1);
      expect(bridge.promptedRelease?.tagName, 'v1.2.3');
      expect(bridge.promptedSubmits, ['first change', 'second change']);
      expect(bridge.downloadedAssets, ['https://example.com/arm64.apk']);
      expect(bridge.prepareCalls, 1);
      expect(bridge.installCalls, 1);
      expect(bridge.lastInstallPath, installedFile.path);
      expect(installedFile.existsSync(), isTrue);
      expect(runnerTitles, ['Check update', 'Update']);
      expect(bridge.installErrorMessage, isNull);
    });

    test('reuses a verified cached APK and resolves checksum from sidecar file',
        () async {
      final bytes = utf8.encode('cached-release');
      final digest = sha256.convert(bytes).toString();
      final cachedFile =
          File('${tempDir.path}/FlClashM-1.2.3-android-arm64-v8a.apk')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes, flush: true);
      final release = AppRelease(
        tagName: 'v1.2.3',
        body: '',
        htmlUrl: 'https://example.com/releases/v1.2.3',
        assets: [
          ReleaseAsset(
            name: 'FlClashM-1.2.3-android-arm64-v8a.apk',
            browserDownloadUrl: 'https://example.com/arm64.apk',
            size: bytes.length,
          ),
          ReleaseAsset(
            name: 'FlClashM-1.2.3-android-arm64-v8a.apk.sha256',
            browserDownloadUrl: 'https://example.com/arm64.apk.sha256',
            size: 80,
          ),
        ],
        prerelease: false,
        draft: false,
      );
      final bridge = _FakeUpdateBridge(
        updateDirectoryPath: tempDir.path,
        checkResult: release,
        promptResult: true,
      )..remoteTexts['https://example.com/arm64.apk.sha256'] =
          '$digest  FlClashM-1.2.3-android-arm64-v8a.apk\n';
      final service = AppUpdateService(platform: bridge);

      await service.handleCheckResult(
        release: release,
        trigger: AppUpdateCheckTrigger.manual,
      );

      expect(cachedFile.existsSync(), isTrue);
      expect(bridge.downloadedAssets, isEmpty);
      expect(bridge.prepareCalls, 1);
      expect(bridge.installCalls, 1);
      expect(bridge.lastInstallPath, cachedFile.path);
    });

    test('matches checksum sidecar entries to the selected APK asset',
        () async {
      final bytes = utf8.encode('arm64-release');
      final digest = sha256.convert(bytes).toString();
      final wrongDigest =
          sha256.convert(utf8.encode('wrong-release')).toString();
      final release = AppRelease(
        tagName: 'v1.2.3',
        body: '',
        htmlUrl: 'https://example.com/releases/v1.2.3',
        assets: [
          ReleaseAsset(
            name: 'FlClashM-1.2.3-android-arm64-v8a.apk',
            browserDownloadUrl: 'https://example.com/arm64.apk',
            size: bytes.length,
          ),
          ReleaseAsset(
            name: 'FlClashM-1.2.3-android-arm64-v8a.apk.sha256',
            browserDownloadUrl: 'https://example.com/arm64.apk.sha256',
            size: 160,
          ),
        ],
        prerelease: false,
        draft: false,
      );
      final bridge = _FakeUpdateBridge(
        updateDirectoryPath: tempDir.path,
        checkResult: release,
        promptResult: true,
      )
        ..assetBytesByUrl['https://example.com/arm64.apk'] = bytes
        ..remoteTexts['https://example.com/arm64.apk.sha256'] = '''
$wrongDigest  FlClashM-1.2.3-android-universal.apk
$digest  FlClashM-1.2.3-android-arm64-v8a.apk
''';
      final service = AppUpdateService(platform: bridge);

      await service.handleCheckResult(
        release: release,
        trigger: AppUpdateCheckTrigger.manual,
      );

      expect(bridge.installErrorMessage, isNull);
      expect(bridge.installCalls, 1);
      expect(
        bridge.lastInstallPath,
        '${tempDir.path}/FlClashM-1.2.3-android-arm64-v8a.apk',
      );
    });

    test('shows explicit error on manual check when no update is returned',
        () async {
      final bridge = _FakeUpdateBridge(updateDirectoryPath: tempDir.path);
      final service = AppUpdateService(platform: bridge);
      String? loadingTitle;

      Future<T?> runTask<T>(Future<T> Function() task, {String? title}) async {
        loadingTitle = title;
        return task();
      }

      await service.manualCheck(
        runTask: runTask,
        loadingTitle: 'Check update',
      );

      expect(bridge.checkCalls, 1);
      expect(loadingTitle, 'Check update');
      expect(bridge.errorCalls, 1);
      expect(bridge.installCalls, 0);
    });

    test('reports install errors when SHA256 verification fails', () async {
      final release = AppRelease(
        tagName: 'v1.2.3',
        body: '',
        htmlUrl: 'https://example.com/releases/v1.2.3',
        assets: [
          ReleaseAsset(
            name: 'FlClashM-1.2.3-android-arm64-v8a.apk',
            browserDownloadUrl: 'https://example.com/arm64.apk',
            size: 4,
            digest:
                'sha256:1111111111111111111111111111111111111111111111111111111111111111',
          ),
        ],
        prerelease: false,
        draft: false,
      );
      final bridge = _FakeUpdateBridge(
        updateDirectoryPath: tempDir.path,
        checkResult: release,
        promptResult: true,
        openReleasePageOnError: true,
      )..assetBytesByUrl['https://example.com/arm64.apk'] = [1, 2, 3, 4];
      final service = AppUpdateService(platform: bridge);

      await service.handleCheckResult(
        release: release,
        trigger: AppUpdateCheckTrigger.manual,
      );

      expect(bridge.installCalls, 0);
      expect(
          bridge.installErrorMessage, contains('SHA256 verification failed'));
      expect(
        bridge.installErrorReleaseUrl,
        'https://example.com/releases/v1.2.3',
      );
      expect(
        bridge.openedReleaseUrls,
        ['https://example.com/releases/v1.2.3'],
      );
    });

    test('delegates package install through the platform bridge', () async {
      final bridge = _FakeUpdateBridge(updateDirectoryPath: tempDir.path);
      final service = AppUpdateService(platform: bridge);

      final installed = await service.installPackage('/tmp/app.apk');

      expect(installed, isTrue);
      expect(bridge.installCalls, 1);
      expect(bridge.lastInstallPath, '/tmp/app.apk');
    });

    test('reports installer handoff failures to the user', () async {
      final bytes = utf8.encode('arm64-release');
      final digest = sha256.convert(bytes).toString();
      final release = AppRelease(
        tagName: 'v1.2.3',
        body: '',
        htmlUrl: 'https://example.com/releases/v1.2.3',
        assets: [
          ReleaseAsset(
            name: 'FlClashM-android-arm64-v8a.apk',
            browserDownloadUrl: 'https://example.com/arm64.apk',
            size: bytes.length,
            digest: 'sha256:$digest',
          ),
        ],
        prerelease: false,
        draft: false,
      );
      final bridge = _FakeUpdateBridge(
        updateDirectoryPath: tempDir.path,
        checkResult: release,
        promptResult: true,
        installResult: false,
        openReleasePageOnError: true,
      )..assetBytesByUrl['https://example.com/arm64.apk'] = bytes;
      final service = AppUpdateService(platform: bridge);

      await service.handleCheckResult(
        release: release,
        trigger: AppUpdateCheckTrigger.manual,
      );

      expect(bridge.prepareCalls, 1);
      expect(bridge.installCalls, 1);
      expect(
        bridge.installErrorMessage,
        contains('Unable to open the Android installer'),
      );
      expect(
        bridge.installErrorReleaseUrl,
        'https://example.com/releases/v1.2.3',
      );
      expect(
        bridge.openedReleaseUrls,
        ['https://example.com/releases/v1.2.3'],
      );
    });
  });
}
