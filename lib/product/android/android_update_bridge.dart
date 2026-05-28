import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../plugins/app.dart';
import '../../state.dart';
import '../services/app_update_release.dart';

final Dio _appUpdateDio = Dio(
  BaseOptions(
    headers: {
      'User-Agent': browserUa,
    },
  ),
);

abstract interface class AppUpdatePlatformBridge {
  String get latestReleaseUrl;

  Future<AppRelease?> checkForAppUpdate();

  Future<bool?> promptForUpdateDownload({
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
    void Function(int received, int total)? onReceiveProgress,
  });

  Future<String> getUpdateDirectoryPath();

  Future<void> prepareInstallHandoff();

  Future<bool> openReleasePage(String url);

  Future<bool> installPackage(String path);
}

class AndroidUpdateBridge implements AppUpdatePlatformBridge {
  const AndroidUpdateBridge();

  @override
  String get latestReleaseUrl =>
      'https://github.com/$repository/releases/latest';

  @override
  Future<AppRelease?> checkForAppUpdate() async {
    try {
      final response = await _appUpdateDio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      final data = response.data;
      if (response.statusCode != 200 || data == null) {
        return null;
      }

      final release = AppRelease.fromJson(Map<String, dynamic>.from(data));
      final hasUpdate = utils.compareVersions(
              release.version, globalState.packageInfo.version) >
          0;
      return hasUpdate ? release : null;
    } catch (error) {
      commonPrint.log('Failed to check app updates: $error');
      return null;
    }
  }

  @visibleForTesting
  @override
  Future<bool?> promptForUpdateDownload({
    required AppRelease release,
    required List<String> submits,
  }) async {
    final textTheme = globalState.navigatorKey.currentContext?.textTheme;
    return globalState.showMessage(
      title: appLocalizations.discoverNewVersion,
      message: TextSpan(
        text: '${release.tagName} \n',
        style: textTheme?.headlineSmall,
        children: [
          TextSpan(text: "\n", style: textTheme?.bodyMedium),
          for (final submit in submits)
            TextSpan(text: "- $submit \n", style: textTheme?.bodyMedium),
        ],
      ),
      confirmText: appLocalizations.goDownload,
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
  Future<String?> readRemoteText(String url) async {
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
  Future<void> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    await _appUpdateDio.download(
      asset.browserDownloadUrl,
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
