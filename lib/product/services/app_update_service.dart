// ignore_for_file: annotate_overrides

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../common/common.dart';
import '../android/android_update_bridge.dart';
import 'app_update_release.dart';
import 'product_update_service.dart';

enum AppUpdateCheckTrigger {
  automatic,
  manual,
}

class AppUpdateService implements ProductUpdateService {
  const AppUpdateService({
    this.platform = const AndroidUpdateBridge(),
  });

  final AppUpdatePlatformBridge platform;

  Future<void> autoCheck({
    required bool enabled,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
  }) async {
    if (!enabled) {
      return;
    }

    final release = await platform.checkForAppUpdate(
      includePrerelease: includePrerelease,
      skippedTagName: skippedTagName,
    );
    await handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.automatic,
      onSkipRelease: onSkipRelease,
    );
  }

  Future<void> manualCheck({
    required AsyncTaskRunner runTask,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
    String? loadingTitle,
  }) async {
    final release = await runTask(
      () => platform.checkForAppUpdate(
        includePrerelease: includePrerelease,
        skippedTagName: skippedTagName,
      ),
      title: loadingTitle,
    );
    await handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.manual,
      onSkipRelease: onSkipRelease,
    );
  }

  Future<void> handleCheckResult({
    required AppRelease? release,
    required AppUpdateCheckTrigger trigger,
    SkipAppUpdateRelease? onSkipRelease,
  }) async {
    if (release != null) {
      final action = await platform.promptForUpdateDownload(
        release: release,
        submits: utils.parseReleaseBody(release.body),
      );
      if (action == AppUpdatePromptAction.skip) {
        await onSkipRelease?.call(release.tagName);
        return;
      }
      if (action == AppUpdatePromptAction.download) {
        try {
          await _downloadAndInstallRelease(release);
        } on AppUpdateDownloadCancelledException {
          // Пользователь сам прервал загрузку — это не ошибка.
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

    final String actualSha256;
    try {
      actualSha256 = await platform.showDownloadProgress<String>(
        release: release,
        asset: androidAsset.apkAsset,
        downloadTask: (onReceiveProgress, cancellation) =>
            platform.downloadReleaseAsset(
          androidAsset.apkAsset,
          tempFile.path,
          expectedSha256: expectedSha256,
          onReceiveProgress: onReceiveProgress,
          cancellation: cancellation,
        ),
      );
    } on AppUpdateDownloadCancelledException {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
      rethrow;
    }

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

  Future<bool> installPackage(String path) => platform.installPackage(path);
}
