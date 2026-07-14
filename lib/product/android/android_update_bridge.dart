import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../plugins/app.dart';
import '../../state.dart';
import '../../widgets/dialog.dart';
import '../services/app_update_manifest.dart';
import '../services/app_update_release.dart';

final Dio _appUpdateDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 30),
    headers: {
      'User-Agent': browserUa,
    },
  ),
);

abstract interface class AppUpdateHttpClient {
  Future<List<int>> readBytes(String url);

  Future<List<dynamic>> readJsonList(String url);

  Future<String?> readText(String url);

  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
  });
}

class DioAppUpdateHttpClient implements AppUpdateHttpClient {
  const DioAppUpdateHttpClient();

  @override
  Future<List<int>> readBytes(String url) async {
    final response = await _appUpdateDio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw StateError('Unable to read `$url`.');
    }
    return data;
  }

  @override
  Future<List<dynamic>> readJsonList(String url) async {
    final response = await _appUpdateDio.get<List<dynamic>>(
      url,
      options: Options(responseType: ResponseType.json),
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw StateError('Unable to read `$url`.');
    }
    return data;
  }

  @override
  Future<String?> readText(String url) async {
    final response = await _appUpdateDio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    if (response.statusCode != 200) {
      return null;
    }
    return response.data;
  }

  @override
  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    await _appUpdateDio.download(
      url,
      targetPath,
      onReceiveProgress: onReceiveProgress,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'User-Agent': globalState.ua,
        },
      ),
    );
  }
}

abstract interface class AppUpdatePlatformBridge {
  String get latestReleaseUrl;

  Future<AppRelease?> checkForAppUpdate({
    required bool includePrerelease,
    required String skippedTagName,
  });

  Future<AppUpdatePromptAction?> promptForUpdateDownload({
    required AppRelease release,
    required List<String> submits,
  });

  Future<void> showUpdateCheckError();

  Future<void> showUpdateInstallError({
    required String message,
    required String releaseUrl,
  });

  Future<List<String>> readSupportedAbis();

  Future<String?> readRemoteText(String url);

  Future<void> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
  });

  Future<T> showDownloadProgress<T>({
    required AppRelease release,
    required ReleaseAsset asset,
    required Future<T> Function(
      void Function(int received, int total) onReceiveProgress,
    ) downloadTask,
  });

  Future<String> getUpdateDirectoryPath();

  Future<void> prepareInstallHandoff();

  Future<bool> openReleasePage(String url);

  Future<bool> installPackage(String path);
}

enum AppUpdatePromptAction {
  download,
  later,
  skip,
}

class AndroidUpdateBridge implements AppUpdatePlatformBridge {
  const AndroidUpdateBridge({
    this.manifestVerifier = const AppUpdateManifestVerifier(),
    this.rollbackGuard =
        const SharedPreferencesAppUpdateManifestRollbackGuard(),
    this.httpClient = const DioAppUpdateHttpClient(),
  });

  final AppUpdateManifestVerifier manifestVerifier;
  final AppUpdateManifestRollbackGuard rollbackGuard;
  final AppUpdateHttpClient httpClient;

  @override
  String get latestReleaseUrl => '$sourceForgeProjectUrl/files/releases/';

  @override
  Future<AppRelease?> checkForAppUpdate({
    required bool includePrerelease,
    required String skippedTagName,
  }) async {
    final sourceForge = await _readSourceForgeReleases(
      includePrerelease: includePrerelease,
    );
    final availableReleases = <AppRelease>[
      ...sourceForge.releases,
      if (!sourceForge.complete) ...await _readGitHubReleases(),
    ];
    final release = selectLatestAppRelease(
      availableReleases,
      includePrerelease: includePrerelease,
    );
    if (release == null || release.tagName == skippedTagName.trim()) {
      return null;
    }

    final hasUpdate = utils.compareVersions(
          release.version,
          globalState.packageInfo.version,
        ) >
        0;
    return hasUpdate ? release : null;
  }

  Future<({List<AppRelease> releases, bool complete})>
      _readSourceForgeReleases({
    required bool includePrerelease,
  }) async {
    final channels = <AppUpdateChannel>[
      AppUpdateChannel.stable,
      if (includePrerelease) AppUpdateChannel.prerelease,
    ];
    final releases = <AppRelease>[];
    var complete = true;
    for (final channel in channels) {
      try {
        final manifestBytes = await httpClient.readBytes(
          appUpdateManifestUrl(channel),
        );
        final signatureBytes = await httpClient.readBytes(
          appUpdateManifestSignatureUrl(channel),
        );
        final manifest = await manifestVerifier.verifyAndDecode(
          manifestBytes: manifestBytes,
          signatureBytes: signatureBytes,
          expectedChannel: channel,
        );
        await rollbackGuard.validateAndRecord(manifest);
        releases.add(manifest.toRelease());
      } catch (error) {
        complete = false;
        commonPrint.log(
          'Failed to read signed ${channel.wireName} app update manifest: '
          '$error',
        );
      }
    }
    return (releases: releases, complete: complete);
  }

  Future<List<AppRelease>> _readGitHubReleases() async {
    try {
      final data = await httpClient.readJsonList(
        'https://api.github.com/repos/$repository/releases?per_page=20',
      );
      return data
          .whereType<Map>()
          .map((item) => AppRelease.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } catch (error) {
      commonPrint.log('Failed to read GitHub app releases: $error');
      return const [];
    }
  }

  @visibleForTesting
  @override
  Future<AppUpdatePromptAction?> promptForUpdateDownload({
    required AppRelease release,
    required List<String> submits,
  }) async {
    final textTheme = globalState.navigatorKey.currentContext?.textTheme;
    return globalState.showCommonDialog<AppUpdatePromptAction>(
      child: Builder(
        builder: (context) => CommonDialog(
          title: appLocalizations.discoverNewVersion,
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(AppUpdatePromptAction.skip);
              },
              child: Text(appLocalizations.skipVersion),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(AppUpdatePromptAction.later);
              },
              child: Text(appLocalizations.later),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(AppUpdatePromptAction.download);
              },
              child: Text(appLocalizations.goDownload),
            ),
          ],
          child: SelectableText.rich(
            TextSpan(
              text: '${release.tagName}\n',
              style: textTheme?.headlineSmall,
              children: [
                if (release.prerelease)
                  TextSpan(
                    text: '${appLocalizations.includePrereleaseUpdates}\n',
                    style: textTheme?.labelMedium,
                  ),
                TextSpan(text: '\n', style: textTheme?.bodyMedium),
                for (final submit in submits)
                  TextSpan(text: '- $submit\n', style: textTheme?.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @visibleForTesting
  @override
  Future<void> showUpdateCheckError() async {
    await globalState.showMessage(
      title: appLocalizations.checkUpdate,
      message: TextSpan(text: appLocalizations.checkUpdateError),
    );
  }

  @visibleForTesting
  @override
  Future<void> showUpdateInstallError({
    required String message,
    required String releaseUrl,
  }) async {
    final shouldOpenReleasePage = await globalState.showMessage(
      title: appLocalizations.update,
      message: TextSpan(text: message),
      confirmText: appLocalizations.goDownload,
    );
    if (shouldOpenReleasePage ?? false) {
      await openReleasePage(releaseUrl);
    }
  }

  @override
  Future<List<String>> readSupportedAbis() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return androidInfo.supportedAbis
        .where((abi) => abi.trim().isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<String?> readRemoteText(String url) => httpClient.readText(url);

  @override
  Future<void> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    Object? lastError;
    for (final url in asset.downloadUrls) {
      final target = File(targetPath);
      try {
        if (target.existsSync()) {
          target.deleteSync();
        }
        await httpClient.download(
          url,
          targetPath,
          onReceiveProgress: onReceiveProgress,
        );
        final actualSha256 = await computeFileSha256(target);
        if (actualSha256 != expectedSha256) {
          throw StateError('SHA256 verification failed for mirror `$url`.');
        }
        return;
      } catch (error) {
        lastError = error;
        commonPrint.log('Failed to download app update mirror `$url`: $error');
        if (target.existsSync()) {
          target.deleteSync();
        }
      }
    }
    throw StateError('All app update mirrors failed: $lastError');
  }

  @visibleForTesting
  @override
  Future<T> showDownloadProgress<T>({
    required AppRelease release,
    required ReleaseAsset asset,
    required Future<T> Function(
      void Function(int received, int total) onReceiveProgress,
    ) downloadTask,
  }) async {
    final progress = ValueNotifier<_DownloadProgress>(
      const _DownloadProgress(received: 0, total: 0),
    );
    NavigatorState? progressNavigator;
    final dialogFuture = globalState.showCommonDialog<void>(
      dismissible: false,
      child: Builder(
        builder: (context) {
          progressNavigator ??= Navigator.of(context);
          return _UpdateDownloadProgressDialog(
            release: release,
            asset: asset,
            progress: progress,
          );
        },
      ),
    );

    try {
      await Future<void>.delayed(Duration.zero);
      final result = await downloadTask((received, total) {
        progress.value = _DownloadProgress(
          received: received,
          total: total,
        );
      });
      _closeProgressDialog(progressNavigator);
      await dialogFuture;
      return result;
    } catch (_) {
      _closeProgressDialog(progressNavigator);
      await dialogFuture;
      rethrow;
    } finally {
      progress.dispose();
    }
  }

  void _closeProgressDialog(NavigatorState? navigator) {
    if (navigator == null) {
      return;
    }
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Future<String> getUpdateDirectoryPath() async {
    final homeDir = await appPath.homeDirPath;
    final directory = Directory(path.join(homeDir, 'updates'));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<void> prepareInstallHandoff() async {
    if (!Platform.isAndroid) {
      return;
    }

    final runtimeBeforeInstall = await clashLib?.getRunTime();
    final shouldStopRuntime =
        runtimeBeforeInstall != null || globalState.isStart;
    if (!shouldStopRuntime) {
      return;
    }

    commonPrint
        .log('Stopping Android runtime before launching in-app installer');
    try {
      await globalState.engineManager.stop();
    } catch (error) {
      commonPrint.log(
        'Failed to stop Android runtime through EngineManager before '
        'installer handoff: $error',
      );
      try {
        await clashLib?.stopVpn();
      } catch (fallbackError) {
        commonPrint.log(
          'Fallback Android VPN stop before installer handoff also failed: '
          '$fallbackError',
        );
      }
    }

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final runtime = await clashLib?.getRunTime();
      if (runtime == null) {
        return;
      }
    }

    commonPrint.log(
      'Android runtime was still reported as active before installer launch; '
      'continuing with best-effort update flow.',
    );
  }

  @visibleForTesting
  @override
  Future<bool> openReleasePage(String url) => launchUrl(Uri.parse(url));

  @override
  Future<bool> installPackage(String path) async =>
      await app?.openFile(path) ?? false;
}

class _UpdateDownloadProgressDialog extends StatelessWidget {
  const _UpdateDownloadProgressDialog({
    required this.release,
    required this.asset,
    required this.progress,
  });

  final AppRelease release;
  final ReleaseAsset asset;
  final ValueNotifier<_DownloadProgress> progress;

  @override
  Widget build(BuildContext context) => CommonDialog(
        title: appLocalizations.downloadUpdate,
        overrideScroll: true,
        child: ValueListenableBuilder<_DownloadProgress>(
          valueListenable: progress,
          builder: (context, value, _) {
            final fraction = value.fraction;
            final percent = fraction == null
                ? appLocalizations.download
                : '${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  release.tagName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  asset.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: fraction),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(percent),
                    Text(value.sizeText),
                  ],
                ),
              ],
            );
          },
        ),
      );
}

class _DownloadProgress {
  const _DownloadProgress({
    required this.received,
    required this.total,
  });

  final int received;
  final int total;

  double? get fraction {
    if (total <= 0) {
      return null;
    }
    return received / total;
  }

  String get sizeText {
    if (total <= 0) {
      return _formatBytes(received);
    }
    return '${_formatBytes(received)} / ${_formatBytes(total)}';
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    if (unitIndex == 0) {
      return '${value.toStringAsFixed(0)} ${units[unitIndex]}';
    }
    return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
  }
}
