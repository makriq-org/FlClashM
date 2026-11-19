import 'dart:convert';
import 'dart:io';

import 'package:flclashx/product/android/android_update_bridge.dart';
import 'package:flclashx/product/services/app_update_http.dart';
import 'package:flclashx/product/services/app_update_identity.dart';
import 'package:flclashx/product/services/app_update_install_journal.dart';
import 'package:flclashx/product/services/app_update_release.dart';
import 'package:flclashx/product/services/app_update_service.dart';
import 'package:flclashx/product/services/app_update_session.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _FakeJournal implements AppUpdateInstallJournal {
  int? prepared;

  @override
  Future<int?> readPreparedVersionCode() async => prepared;

  @override
  Future<void> recordPrepared(int versionCode) async => prepared = versionCode;

  @override
  Future<void> clear() async => prepared = null;
}

final _signer = 'a' * 64;

class _FakeUpdateBridge implements AppUpdatePlatformBridge {
  _FakeUpdateBridge({required this.updateDirectoryPath});

  final String updateDirectoryPath;
  final journal = _FakeJournal();
  final List<String> supportedAbis = const ['arm64-v8a'];
  final includePrereleaseArgs = <bool>[];
  final skippedTagNameArgs = <String>[];
  final downloadedAssets = <String>[];
  final installPaths = <String>[];
  final openedReleaseUrls = <String>[];
  final remoteTexts = <String, String?>{};
  final assetBytesByUrl = <String, List<int>>{};

  AppRelease? checkResult;
  AppUpdateWindowResult? windowResult;
  bool installResult = true;
  int checkCalls = 0;
  int errorCalls = 0;
  int installCalls = 0;
  int prepareCalls = 0;
  int pruneCalls = 0;
  AppRelease? promptedRelease;
  List<String>? promptedSubmits;
  bool? promptedRequired;
  AppUpdateSession? promptedSession;
  Future<void> Function(AppUpdateSession session)? driveSession;

  @override
  String get latestReleaseUrl => 'https://example.com/releases/latest';

  @override
  AppUpdateInstallJournal get installJournal => journal;

  @override
  Future<AppRelease?> checkForAppUpdate({
    required bool includePrerelease,
    required String skippedTagName,
  }) async {
    checkCalls++;
    includePrereleaseArgs.add(includePrerelease);
    skippedTagNameArgs.add(skippedTagName);
    return checkResult;
  }

  @override
  Future<AppUpdateWindowResult?> showUpdateWindow({
    required AppRelease release,
    required List<String> submits,
    required AppUpdateSession session,
  }) async {
    promptedRelease = release;
    promptedSubmits = submits;
    promptedRequired = session.requiredUpdate;
    promptedSession = session;
    await driveSession?.call(session);
    return windowResult;
  }

  @override
  Future<void> showUpdateCheckError() async => errorCalls++;

  @override
  Future<bool> openReleasePage(String url) async {
    openedReleaseUrls.add(url);
    return true;
  }

  @override
  Future<void> pruneInstalledUpdates() async => pruneCalls++;

  @override
  Future<List<String>> readSupportedAbis() async => supportedAbis;

  @override
  Future<String> getUpdateDirectoryPath() async => updateDirectoryPath;

  @override
  Future<String?> readRemoteText(String url) async => remoteTexts[url];

  @override
  Future<String> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
  }) async {
    downloadedAssets.add(asset.browserDownloadUrl);
    final bytes = assetBytesByUrl[asset.browserDownloadUrl];
    if (bytes == null) {
      throw StateError('Missing fake asset payload.');
    }
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    onReceiveProgress?.call(bytes.length, bytes.length);
    return expectedSha256;
  }

  @override
  Future<AppUpdatePackageIdentity?> inspectInstalledPackage() async =>
      installedIdentity;

  @override
  Future<AppUpdatePackageIdentity?> inspectPackage(String path) async =>
      candidateIdentity;

  @override
  Future<void> prepareInstallHandoff() async => prepareCalls++;

  @override
  Future<bool> installPackage(String path) async {
    installCalls++;
    installPaths.add(path);
    return installResult;
  }

  AppUpdatePackageIdentity? installedIdentity = AppUpdatePackageIdentity(
    packageName: 'com.makriq.flclash',
    versionCode: 2026110101,
    signers: {_signer},
  );

  AppUpdatePackageIdentity? candidateIdentity = AppUpdatePackageIdentity(
    packageName: 'com.makriq.flclash',
    versionCode: 2026111801,
    signers: {_signer},
  );
}

AppRelease _release({
  String body = '- первое изменение\n- второе изменение',
  int versionCode = 2026111801,
  String? minimumVersion,
  int? minimumVersionCode,
}) => AppRelease(
  tagName: 'v1.2.3',
  body: body,
  htmlUrl: 'https://example.com/releases/v1.2.3',
  assets: [
    ReleaseAsset(
      name: 'FlClashM-android-arm64-v8a.apk',
      browserDownloadUrl: 'https://example.com/arm64.apk',
      size: 4,
      versionCode: versionCode,
      digest: 'sha256:${_digestOfFakePayload()}',
    ),
  ],
  prerelease: false,
  draft: false,
  versionCode: versionCode,
  minimumVersion: minimumVersion,
  minimumVersionCode: minimumVersionCode,
);

/// SHA-256 of the `test` payload the fake downloader writes.
String _digestOfFakePayload() =>
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

void main() {
  late Directory tempDir;
  late _FakeUpdateBridge bridge;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app-update-service-');
    bridge = _FakeUpdateBridge(updateDirectoryPath: tempDir.path);
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

  test('cleans stale downloads before an automatic check', () async {
    final service = AppUpdateService(platform: bridge);

    await service.autoCheck(
      enabled: false,
      includePrerelease: false,
      skippedTagName: '',
    );

    expect(bridge.pruneCalls, 1);
    expect(bridge.checkCalls, 0);
    expect(bridge.errorCalls, 0);
  });

  test('passes update channel and skipped tag to automatic checks', () async {
    final service = AppUpdateService(platform: bridge);

    await service.autoCheck(
      enabled: true,
      includePrerelease: true,
      skippedTagName: 'v1.2.3',
    );

    expect(bridge.checkCalls, 1);
    expect(bridge.includePrereleaseArgs, [true]);
    expect(bridge.skippedTagNameArgs, ['v1.2.3']);
    expect(bridge.pruneCalls, 1);
  });

  test('opens one window with the notes and a manual trigger', () async {
    bridge.checkResult = _release();
    final service = AppUpdateService(platform: bridge);
    String? loadingTitle;

    Future<T?> runTask<T>(Future<T> Function() task, {String? title}) async {
      loadingTitle = title;
      return task();
    }

    await service.manualCheck(
      runTask: runTask,
      includePrerelease: false,
      skippedTagName: '',
      loadingTitle: 'Check update',
    );

    expect(loadingTitle, 'Check update');
    expect(bridge.promptedRelease?.tagName, 'v1.2.3');
    expect(bridge.promptedSubmits, ['первое изменение', 'второе изменение']);
    expect(bridge.promptedRequired, isFalse);
    // Ручная проверка не убирает файлы: она не подтверждает обновление.
    expect(bridge.pruneCalls, 0);
  });

  test('a required update from the signed catalog cannot be skipped',
      () async {
    bridge.checkResult = _release(minimumVersionCode: 2026111801);
    final service = AppUpdateService(platform: bridge);

    await service.handleCheckResult(
      release: bridge.checkResult,
      trigger: AppUpdateCheckTrigger.manual,
    );

    expect(bridge.promptedRequired, isTrue);
  });

  test('skipping remembers the tag, closing does not', () async {
    bridge.checkResult = _release();
    final skipped = <String>[];
    final service = AppUpdateService(platform: bridge);

    bridge.windowResult = AppUpdateWindowResult.later;
    await service.handleCheckResult(
      release: bridge.checkResult,
      trigger: AppUpdateCheckTrigger.manual,
      onSkipRelease: (tagName) async => skipped.add(tagName),
    );
    expect(skipped, isEmpty);

    bridge.windowResult = AppUpdateWindowResult.skip;
    await service.handleCheckResult(
      release: bridge.checkResult,
      trigger: AppUpdateCheckTrigger.manual,
      onSkipRelease: (tagName) async => skipped.add(tagName),
    );
    expect(skipped, ['v1.2.3']);
  });

  test('download and install run only when the user asks for them', () async {
    final release = _release();
    bridge.checkResult = release;
    bridge.assetBytesByUrl['https://example.com/arm64.apk'] = utf8.encode(
      'test',
    );
    final service = AppUpdateService(platform: bridge);
    bridge.driveSession = (session) async {
      await session.download();
      expect(session.phase, AppUpdatePhase.ready);
      expect(bridge.installCalls, 0);
      await session.install();
    };

    await service.handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.manual,
    );

    expect(bridge.installCalls, 1);
    expect(bridge.prepareCalls, 1);
    expect(bridge.journal.prepared, 2026111801);
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk').existsSync(),
      isTrue,
    );
  });

  test('a manual check without a release reports it', () async {
    final service = AppUpdateService(platform: bridge);

    await service.handleCheckResult(
      release: null,
      trigger: AppUpdateCheckTrigger.manual,
    );

    expect(bridge.errorCalls, 1);
    expect(bridge.promptedRelease, isNull);
  });

  test('an automatic check without a release stays quiet', () async {
    final service = AppUpdateService(platform: bridge);

    await service.handleCheckResult(
      release: null,
      trigger: AppUpdateCheckTrigger.automatic,
    );

    expect(bridge.errorCalls, 0);
  });
}
