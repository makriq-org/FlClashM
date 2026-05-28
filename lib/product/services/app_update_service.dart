import 'dart:io';

import 'package:path/path.dart' as path;

import '../../common/common.dart';
import '../../state.dart';
import '../android/android_update_bridge.dart';
import 'app_update_release.dart';

typedef AsyncTaskRunner = Future<T?> Function<T>(
  Future<T> Function() task, {
  String? title,
});

enum AppUpdateCheckTrigger {
  automatic,
  manual,
}

class AppUpdateService {
  const AppUpdateService({
    this.platform = const AndroidUpdateBridge(),
  });

  final AppUpdatePlatformBridge platform;

  Future<void> autoCheck({required bool enabled}) async {
    if (!enabled || globalState.isPre) {
      return;
    }

    final release = await platform.checkForAppUpdate();
    await handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.automatic,
    );
  }

  Future<void> manualCheck({
    required AsyncTaskRunner runTask,
    String? loadingTitle,
    String? installTitle,
  }) async {
    if (globalState.isPre) {
      return;
    }

    final release = await runTask(
      platform.checkForAppUpdate,
      title: loadingTitle,
    );
    await handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.manual,
      runTask: runTask,
      installTitle: installTitle,
    );
  }

  Future<void> handleCheckResult({
    required AppRelease? release,
    required AppUpdateCheckTrigger trigger,
    AsyncTaskRunner? runTask,
    String? installTitle,
  }) async {
    if (release != null) {
      final confirmed = await platform.promptForUpdateDownload(
        release: release,
        submits: utils.parseReleaseBody(release.body),
      );
      if (confirmed ?? false) {
        try {
          if (runTask != null) {
            await runTask<void>(
              () => _downloadAndInstallRelease(release),
              title: installTitle ?? _defaultInstallTitle,
            );
          } else {
            await _downloadAndInstallRelease(release);
          }
        } catch (error) {
          await platform.showUpdateInstallError(
            message: '$error',
            releaseUrl: release.htmlUrl.isNotEmpty
                ? release.htmlUrl
                : platform.latestReleaseUrl,
          );
        }
      }
      return;
    }

    if (trigger == AppUpdateCheckTrigger.manual) {
      await platform.showUpdateCheckError();
    }
  }

  Future<void> _downloadAndInstallRelease(AppRelease release) async {
    final supportedAbis = await platform.readSupportedAbis();
    final androidAsset = selectAndroidReleaseAsset(
      release,
      supportedAbis: supportedAbis,
    );
    if (androidAsset == null) {
      throw StateError(
        'No compatible Android APK asset was found for '
        '${supportedAbis.join(', ')}.',
      );
    }

    final expectedSha256 = await _resolveExpectedSha256(
      release: release,
      androidAsset: androidAsset,
    );
    if (expectedSha256 == null) {
      throw StateError(
        'No SHA256 checksum is available for `${androidAsset.apkAsset.name}`.',
      );
    }

    final updateDirectoryPath = await platform.getUpdateDirectoryPath();
    final apkPath = path.join(updateDirectoryPath, androidAsset.apkAsset.name);
    final apkFile = File(apkPath);
    if (apkFile.existsSync()) {
      final existingSha256 = await computeFileSha256(apkFile);
      if (existingSha256 == expectedSha256) {
        await _openInstaller(apkFile.path);
        return;
      }
      apkFile.deleteSync();
    }

    final tempFile = File('$apkPath.part');
    await tempFile.parent.create(recursive: true);
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }

    await platform.downloadReleaseAsset(
      androidAsset.apkAsset,
      tempFile.path,
    );

    final actualSha256 = await computeFileSha256(tempFile);
    if (actualSha256 != expectedSha256) {
      await tempFile.delete();
      throw StateError(
        'SHA256 verification failed for `${androidAsset.apkAsset.name}`.',
      );
    }

    if (apkFile.existsSync()) {
      apkFile.deleteSync();
    }
    await tempFile.rename(apkPath);
    await _openInstaller(apkPath);
  }

  Future<String?> _resolveExpectedSha256({
    required AppRelease release,
    required AndroidReleaseAsset androidAsset,
  }) async {
    final inlineDigest = androidAsset.apkAsset.sha256Digest;
    if (inlineDigest != null) {
      return inlineDigest;
    }

    final checksumAsset = androidAsset.checksumAsset;
    if (checksumAsset == null) {
      return null;
    }

    final checksumContent = await platform.readRemoteText(
      checksumAsset.browserDownloadUrl,
    );
    return parseSha256Content(
      checksumContent,
      assetName: androidAsset.apkAsset.name,
    );
  }

  Future<void> _openInstaller(String path) async {
    await platform.prepareInstallHandoff();
    final installed = await platform.installPackage(path);
    if (!installed) {
      throw StateError('Unable to open the Android installer.');
    }
  }

  String get _defaultInstallTitle {
    try {
      return appLocalizations.update;
    } catch (_) {
      return 'Update';
    }
  }

  Future<bool> installPackage(String path) => platform.installPackage(path);
}
