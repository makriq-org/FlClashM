import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import 'app_update_release.dart';

abstract interface class AppUpdateHttpClient {
  Future<List<int>> readBytes(String url);

  Future<List<dynamic>> readJsonList(String url);

  Future<String?> readText(String url);

  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
    int? expectedLength,
  });
}

class AppUpdateDownloadCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

class AppUpdateDownloadCancelledException implements Exception {
  const AppUpdateDownloadCancelledException();

  @override
  String toString() => 'App update download was cancelled by the user.';
}

class DioAppUpdateHttpClient implements AppUpdateHttpClient {
  const DioAppUpdateHttpClient();

  Future<void> _cancelTunnelRequest(String requestId) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await clashCore.cancelTunnelHTTPRequest(requestId)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Future<List<int>> readBytes(String url) async {
    final response = await request.getFileResponseForUrl(url);
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw StateError('Unable to read `$url`.');
    }
    return data;
  }

  @override
  Future<List<dynamic>> readJsonList(String url) async {
    final response = await request.getTextResponseForUrl(url);
    final data = response.data == null ? null : jsonDecode(response.data!);
    if (response.statusCode != 200 || data is! List) {
      throw StateError('Unable to read `$url`.');
    }
    return data;
  }

  @override
  Future<String?> readText(String url) async {
    final response = await request.getTextResponseForUrl(url);
    return response.statusCode == 200 ? response.data : null;
  }

  @override
  Future<void> download(
    String url,
    String targetPath, {
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
    int? expectedLength,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const AppUpdateDownloadCancelledException();
    }
    final requestId = 'app-update-download#${utils.id}';
    final removeCancellationListener = cancellation?.addListener(
      () => unawaited(_cancelTunnelRequest(requestId)),
    );
    try {
      await request.downloadFileForUrl(
        url,
        targetPath,
        onProgress: onReceiveProgress,
        requestId: requestId,
        expectedLength: expectedLength,
      );
    } finally {
      removeCancellationListener?.call();
    }
    if (cancellation?.isCancelled ?? false) {
      throw const AppUpdateDownloadCancelledException();
    }
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

  Future<String> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
  });

  Future<T> showDownloadProgress<T>({
    required AppRelease release,
    required ReleaseAsset asset,
    required Future<T> Function(
      void Function(int received, int total) onReceiveProgress,
      AppUpdateDownloadCancellation cancellation,
    ) downloadTask,
  });

  Future<String> getUpdateDirectoryPath();

  Future<void> prepareInstallHandoff();

  Future<bool> openReleasePage(String url);

  Future<bool> installPackage(String path);
}

enum AppUpdatePromptAction { download, later, skip }

abstract class BaseAppUpdatePlatformBridge implements AppUpdatePlatformBridge {
  const BaseAppUpdatePlatformBridge({
    this.httpClient = const DioAppUpdateHttpClient(),
  });

  final AppUpdateHttpClient httpClient;

  @override
  Future<String?> readRemoteText(String url) => httpClient.readText(url);

  @override
  Future<String> downloadReleaseAsset(
    ReleaseAsset asset,
    String targetPath, {
    required String expectedSha256,
    void Function(int received, int total)? onReceiveProgress,
    AppUpdateDownloadCancellation? cancellation,
  }) async {
    Object? lastError;
    for (final url in asset.downloadUrls) {
      final target = File(targetPath);
      try {
        if (target.existsSync()) target.deleteSync();
        await httpClient.download(
          url,
          targetPath,
          onReceiveProgress: onReceiveProgress,
          cancellation: cancellation,
          expectedLength: asset.size,
        );
        final actualSha256 = await computeFileSha256(target);
        if (actualSha256 != expectedSha256) {
          throw StateError('SHA256 verification failed for mirror `$url`.');
        }
        return actualSha256;
      } catch (error) {
        if (target.existsSync()) target.deleteSync();
        if (cancellation?.isCancelled ?? false) {
          throw const AppUpdateDownloadCancelledException();
        }
        lastError = error;
        commonPrint.log('Failed to download app update mirror `$url`: $error');
      }
    }
    throw StateError('All app update mirrors failed: $lastError');
  }

  @override
  Future<String> getUpdateDirectoryPath() async {
    final homeDir = await appPath.homeDirPath;
    final directory = Directory(path.join(homeDir, 'updates'));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<bool> openReleasePage(String url) => launchUrl(Uri.parse(url));
}
