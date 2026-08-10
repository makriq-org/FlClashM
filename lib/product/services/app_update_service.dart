// ignore_for_file: annotate_overrides

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../common/common.dart';
import '../android/android_update_bridge.dart';
import 'app_update_release.dart';
import 'product_update_service.dart';

enum AppUpdateCheckTrigger { automatic, manual }

class AppUpdateService implements ProductUpdateService {
  const AppUpdateService({
    this.platform = const AndroidUpdateBridge(),
    this.packageSelector = const AndroidAppUpdatePackageSelector(),
  });

  final AppUpdatePlatformBridge platform;
  final AppUpdatePackageSelector packageSelector;

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
    final package = await packageSelector.select(
      release: release,
      platform: platform,
    );

    final updateDirectoryPath = await platform.getUpdateDirectoryPath();
    final packagePath = path.join(updateDirectoryPath, package.asset.name);
    final packageFile = File(packagePath);
    if (packageFile.existsSync()) {
      final existingSha256 = await computeFileSha256(packageFile);
      final existingSize = await packageFile.length();
      if (existingSha256 == package.sha256 &&
          existingSize == package.asset.size) {
        await _openInstaller(packageFile.path);
        return;
      }
      packageFile.deleteSync();
    }

    final tempFile = File('$packagePath.part');
    await tempFile.parent.create(recursive: true);
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }

    final String actualSha256;
    try {
      actualSha256 = await platform.showDownloadProgress<String>(
        release: release,
        asset: package.asset,
        downloadTask: (onReceiveProgress, cancellation) =>
            platform.downloadReleaseAsset(
          package.asset,
          tempFile.path,
          expectedSha256: package.sha256,
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

    final actualSize = tempFile.existsSync() ? await tempFile.length() : -1;
    if (actualSha256 != package.sha256 || actualSize != package.asset.size) {
      await tempFile.delete();
      throw StateError(
        'Package verification failed for `${package.asset.name}`.',
      );
    }

    if (packageFile.existsSync()) {
      packageFile.deleteSync();
    }
    await tempFile.rename(packagePath);
    await _openInstaller(packagePath);
  }

  Future<void> _openInstaller(String path) async {
    await platform.prepareInstallHandoff();
    final installed = await platform.installPackage(path);
    if (!installed) {
      throw StateError('Unable to complete the platform installer handoff.');
    }
  }

  Future<bool> installPackage(String path) => platform.installPackage(path);
}

class AppUpdatePackage {
  const AppUpdatePackage({required this.asset, required this.sha256});

  final ReleaseAsset asset;
  final String sha256;
}

abstract interface class AppUpdatePackageSelector {
  Future<AppUpdatePackage> select({
    required AppRelease release,
    required AppUpdatePlatformBridge platform,
  });
}

class AndroidAppUpdatePackageSelector implements AppUpdatePackageSelector {
  const AndroidAppUpdatePackageSelector();

  @override
  Future<AppUpdatePackage> select({
    required AppRelease release,
    required AppUpdatePlatformBridge platform,
  }) async {
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

    var expectedSha256 = androidAsset.apkAsset.sha256Digest;
    final checksumAsset = androidAsset.checksumAsset;
    if (expectedSha256 == null && checksumAsset != null) {
      expectedSha256 = parseSha256Content(
        await platform.readRemoteText(checksumAsset.browserDownloadUrl),
        assetName: androidAsset.apkAsset.name,
      );
    }
    if (expectedSha256 == null) {
      throw StateError(
        'No SHA256 checksum is available for `${androidAsset.apkAsset.name}`.',
      );
    }
    return AppUpdatePackage(
      asset: androidAsset.apkAsset,
      sha256: expectedSha256,
    );
  }
}
