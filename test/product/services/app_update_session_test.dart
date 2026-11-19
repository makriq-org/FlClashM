import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/product/services/app_update_http.dart';
import 'package:flclashx/product/services/app_update_identity.dart';
import 'package:flclashx/product/services/app_update_install_journal.dart';
import 'package:flclashx/product/services/app_update_release.dart';
import 'package:flclashx/product/services/app_update_session.dart';
import 'package:flutter_test/flutter_test.dart';

final _signer = 'c' * 64;

class _FakeJournal implements AppUpdateInstallJournal {
  int? prepared;
  int records = 0;
  int clears = 0;

  @override
  Future<int?> readPreparedVersionCode() async => prepared;

  @override
  Future<void> recordPrepared(int versionCode) async {
    prepared = versionCode;
    records++;
  }

  @override
  Future<void> clear() async {
    prepared = null;
    clears++;
  }
}

class _FakeInstaller implements AppUpdateInstaller {
  _FakeInstaller({required this.updateDirectoryPath});

  final String updateDirectoryPath;
  final List<String> supportedAbis = const ['arm64-v8a'];
  final downloadedUrls = <String>[];
  final preparedPaths = <String>[];
  final installedPaths = <String>[];
  int installCalls = 0;
  int inspectCalls = 0;
  int remoteTextCalls = 0;
  bool installResult = true;
  Exception? downloadError;
  Exception? inspectError;
  Completer<void>? downloadGate;
  bool cancelWhenGateOpens = false;
  List<int> downloadBytes = [1, 2, 3, 4];
  AppUpdatePackageIdentity? installedIdentity = AppUpdatePackageIdentity(
    packageName: 'com.makriq.flclash',
    versionCode: 2026110101,
    signers: {_signer},
  );
  final Map<String, AppUpdatePackageIdentity?> apkIdentities = {};
  AppUpdatePackageIdentity? defaultApkIdentity = AppUpdatePackageIdentity(
    packageName: 'com.makriq.flclash',
    versionCode: 2026111801,
    signers: {_signer},
  );

  @override
  Future<List<String>> readSupportedAbis() async => supportedAbis;

  @override
  Future<String> getUpdateDirectoryPath() async {
    Directory(updateDirectoryPath).createSync(recursive: true);
    return updateDirectoryPath;
  }

  @override
  Future<String?> readRemoteText(String url) async {
    remoteTextCalls++;
    return null;
  }

  @override
  Future<String> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
  }) async {
    downloadedUrls.add(asset.browserDownloadUrl);
    final error = downloadError;
    if (error != null) {
      throw error;
    }
    final gate = downloadGate;
    if (gate != null) {
      await gate.future;
      if (cancellation?.isCancelled ?? false) {
        throw const AppUpdateDownloadCancelledException();
      }
    }
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(downloadBytes, flush: true);
    onReceiveProgress?.call(downloadBytes.length, downloadBytes.length);
    return sha256.convert(downloadBytes).toString();
  }

  @override
  Future<AppUpdatePackageIdentity?> inspectInstalledPackage() async =>
      installedIdentity;

  @override
  Future<AppUpdatePackageIdentity?> inspectPackage(String path) async {
    inspectCalls++;
    preparedPaths.add(path);
    final error = inspectError;
    if (error != null) {
      throw error;
    }
    return apkIdentities.containsKey(path)
        ? apkIdentities[path]
        : defaultApkIdentity;
  }

  @override
  Future<void> prepareInstallHandoff() async {
    installedPaths.add('handoff');
  }

  @override
  Future<bool> installPackage(String path) async {
    installCalls++;
    installedPaths.add(path);
    return installResult;
  }
}

AppRelease _release({
  int versionCode = 2026111801,
  int size = 4,
  String? digest,
  String? minimumVersion,
  int? minimumVersionCode,
  String assetName = 'FlClashM-android-arm64-v8a.apk',
}) => AppRelease(
  tagName: 'v1.2.3',
  body: '- первое изменение',
  htmlUrl: 'https://example.com/releases/v1.2.3',
  assets: [
    ReleaseAsset(
      name: assetName,
      browserDownloadUrl: 'https://example.com/arm64.apk',
      size: size,
      versionCode: versionCode,
      digest: 'sha256:${digest ?? sha256.convert([1, 2, 3, 4]).toString()}',
    ),
  ],
  prerelease: false,
  draft: false,
  versionCode: versionCode,
  minimumVersion: minimumVersion,
  minimumVersionCode: minimumVersionCode,
);

void main() {
  late Directory tempDir;
  late _FakeInstaller installer;
  late _FakeJournal journal;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app-update-session-');
    installer = _FakeInstaller(updateDirectoryPath: tempDir.path);
    journal = _FakeJournal();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  AppUpdateSession session({AppRelease? release}) => AppUpdateSession(
    release: release ?? _release(),
    installer: installer,
    journal: journal,
  );

  test('downloads and verifies without opening the installer', () async {
    final update = session();

    await update.download();

    expect(update.phase, AppUpdatePhase.ready);
    expect(update.prepared, isNotNull);
    expect(update.prepared?.identity.versionCode, 2026111801);
    expect(installer.downloadedUrls, ['https://example.com/arm64.apk']);
    expect(installer.installCalls, 0);
    expect(installer.installedPaths, isEmpty);
    expect(journal.records, 0);
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk').existsSync(),
      isTrue,
    );
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk.part').existsSync(),
      isFalse,
    );
  });

  test('refuses an asset name that would leave the update directory', () async {
    final update = session(
      release: _release(assetName: '../escape-android-arm64-v8a.apk'),
    );

    await update.download();

    expect(update.phase, AppUpdatePhase.prompt);
    expect(update.failure?.kind, AppUpdateFailureKind.download);
    expect(update.prepared, isNull);
    expect(installer.downloadedUrls, isEmpty);
    expect(
      File('${tempDir.parent.path}/escape-android-arm64-v8a.apk').existsSync(),
      isFalse,
    );
  });

  test('install re-checks the file and hands it to the installer', () async {
    final update = session();
    await update.download();

    await update.install();

    expect(update.phase, AppUpdatePhase.ready);
    expect(update.handedOff, isTrue);
    expect(update.failure, isNull);
    expect(installer.installCalls, 1);
    expect(journal.prepared, 2026111801);
    // APK остаётся: отменённая установка повторяется без загрузки.
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk').existsSync(),
      isTrue,
    );

    await update.install();
    expect(installer.installCalls, 2);
  });

  test('install refuses a file that changed after verification', () async {
    final update = session();
    await update.download();
    File(
      '${tempDir.path}/FlClashM-android-arm64-v8a.apk',
    ).writeAsBytesSync([9, 9, 9, 9], flush: true);

    await update.install();

    expect(installer.installCalls, 0);
    expect(update.phase, AppUpdatePhase.prompt);
    expect(update.failure?.kind, AppUpdateFailureKind.verify);
    expect(update.prepared, isNull);
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk').existsSync(),
      isFalse,
    );
  });

  test('install refuses an APK signed by another certificate', () async {
    final update = session();
    await update.download();
    installer.defaultApkIdentity = AppUpdatePackageIdentity(
      packageName: 'com.makriq.flclash',
      versionCode: 2026111801,
      signers: {'d' * 64},
    );

    await update.install();

    expect(installer.installCalls, 0);
    expect(update.failure?.kind, AppUpdateFailureKind.verify);
    expect(update.prepared, isNull);
  });

  test('a verified APK from an earlier attempt needs no download', () async {
    await session().download();
    final second = session();

    await second.download();

    expect(second.phase, AppUpdatePhase.ready);
    expect(installer.downloadedUrls, hasLength(1));
    expect(installer.inspectCalls, 2);
  });

  test('a corrupted cached APK is deleted and downloaded again', () async {
    File('${tempDir.path}/FlClashM-android-arm64-v8a.apk')
      ..createSync(recursive: true)
      ..writeAsBytesSync([7, 7, 7, 7], flush: true);

    final update = session();
    await update.download();

    expect(update.phase, AppUpdatePhase.ready);
    expect(installer.downloadedUrls, hasLength(1));
  });

  test('cancel returns to the description and removes the partial file',
      () async {
    installer.downloadGate = Completer<void>();
    final update = session();

    final pending = update.download();
    await Future<void>.delayed(Duration.zero);
    expect(update.phase, AppUpdatePhase.downloading);

    update.cancel();
    installer.downloadGate!.complete();
    await pending;

    expect(update.phase, AppUpdatePhase.prompt);
    expect(update.failure, isNull);
    expect(update.prepared, isNull);
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk.part').existsSync(),
      isFalse,
    );
  });

  test('a failed download keeps the window usable and retry downloads again',
      () async {
    installer.downloadError = Exception('all mirrors failed');
    final update = session();

    await update.download();

    expect(update.phase, AppUpdatePhase.prompt);
    expect(update.failure?.kind, AppUpdateFailureKind.download);
    expect(update.canDownload, isTrue);

    installer.downloadError = null;
    await update.retry();

    expect(update.phase, AppUpdatePhase.ready);
    expect(update.failure, isNull);
  });

  test('a failed hand-off keeps the verified APK for another try', () async {
    installer.installResult = false;
    final update = session();
    await update.download();

    await update.install();

    expect(update.phase, AppUpdatePhase.ready);
    expect(update.failure?.kind, AppUpdateFailureKind.install);
    expect(update.canInstall, isTrue);

    installer.installResult = true;
    await update.retry();

    expect(update.failure, isNull);
    expect(update.handedOff, isTrue);
    expect(installer.downloadedUrls, hasLength(1));
    expect(installer.installCalls, 2);
  });

  test('refuses an APK whose code is not the one the catalog describes',
      () async {
    installer.defaultApkIdentity = AppUpdatePackageIdentity(
      packageName: 'com.makriq.flclash',
      versionCode: 2026111802,
      signers: {_signer},
    );

    final update = session();
    await update.download();

    expect(update.phase, AppUpdatePhase.prompt);
    expect(update.failure?.kind, AppUpdateFailureKind.verify);
    expect(update.prepared, isNull);
    expect(
      File('${tempDir.path}/FlClashM-android-arm64-v8a.apk').existsSync(),
      isFalse,
    );
  });

  test('reports a missing compatible asset without touching the disk',
      () async {
    installer.downloadedUrls.clear();
    final update = AppUpdateSession(
      release: AppRelease(
        tagName: 'v1.2.3',
        body: '',
        htmlUrl: 'https://example.com/releases/v1.2.3',
        assets: [
          ReleaseAsset(
            name: 'FlClashM-android-armeabi-v7a.apk',
            browserDownloadUrl: 'https://example.com/arm.apk',
            size: 4,
          ),
        ],
        prerelease: false,
        draft: false,
      ),
      installer: installer,
      journal: journal,
    );

    await update.download();

    expect(update.failure?.kind, AppUpdateFailureKind.download);
    expect(installer.downloadedUrls, isEmpty);
  });

  test('hashes the download in the verifying phase', () async {
    final update = session();
    final phases = <AppUpdatePhase>[];
    update.addListener(() => phases.add(update.phase));

    await update.download();

    expect(phases, contains(AppUpdatePhase.verifying));
    expect(phases.last, AppUpdatePhase.ready);
  });
}
