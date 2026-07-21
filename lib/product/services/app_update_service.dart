import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/common.dart';
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

typedef SkipAppUpdateRelease = Future<void> Function(String tagName);

abstract interface class AutomaticUpdateCheckStore {
  Future<DateTime?> readLastAttempt();

  Future<void> writeLastAttempt(DateTime value);
}

class SharedPreferencesAutomaticUpdateCheckStore
    implements AutomaticUpdateCheckStore {
  const SharedPreferencesAutomaticUpdateCheckStore();

  static const _key = 'flclashm.lastAutomaticUpdateCheckMillis';

  @override
  Future<DateTime?> readLastAttempt() async {
    final millis = (await SharedPreferences.getInstance()).getInt(_key);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  @override
  Future<void> writeLastAttempt(DateTime value) async {
    await (await SharedPreferences.getInstance()).setInt(
      _key,
      value.millisecondsSinceEpoch,
    );
  }
}

class AppUpdateService {
  AppUpdateService({
    this.platform = const AndroidUpdateBridge(),
    AutomaticUpdateCheckStore? automaticCheckStore,
    DateTime Function()? now,
    this.automaticCheckInterval = const Duration(hours: 12),
  })  : automaticCheckStore = automaticCheckStore ??
            const SharedPreferencesAutomaticUpdateCheckStore(),
        now = now ?? DateTime.now;

  final AppUpdatePlatformBridge platform;
  final AutomaticUpdateCheckStore automaticCheckStore;
  final DateTime Function() now;
  final Duration automaticCheckInterval;

  Future<void> autoCheck({
    required bool enabled,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
  }) async {
    if (!enabled) {
      return;
    }
    final attemptTime = now();
    final lastAttempt = await automaticCheckStore.readLastAttempt();
    if (lastAttempt != null) {
      final age = attemptTime.difference(lastAttempt);
      if (!age.isNegative && age < automaticCheckInterval) return;
    }
    // Persist before network I/O so repeated UI opens while offline do not
    // restart the same multi-request check indefinitely.
    await automaticCheckStore.writeLastAttempt(attemptTime);

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

    await platform.showDownloadProgress<void>(
      release: release,
      asset: androidAsset.apkAsset,
      downloadTask: (onReceiveProgress) => platform.downloadReleaseAsset(
        androidAsset.apkAsset,
        tempFile.path,
        expectedSha256: expectedSha256,
        onReceiveProgress: onReceiveProgress,
      ),
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

  Future<bool> installPackage(String path) => platform.installPackage(path);
}
