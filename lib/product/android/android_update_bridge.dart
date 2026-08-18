import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../state.dart';
import '../../widgets/dialog.dart';
import '../services/app_update_manifest.dart';
import '../services/app_update_manifest_release.dart';
import '../services/app_update_manifest_rollback.dart';
import '../services/app_update_release.dart';
import 'android_package_installer.dart';

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

/// Отмена загрузки обновления. Прячет `CancelToken` от вызывающих слоёв,
/// чтобы Dio не протекал в сервис обновлений и его тесты.
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

/// Бросается вместо ошибки загрузки, когда пользователь сам нажал «Отмена»:
/// такой сценарий не должен показывать окно с ошибкой установки.
class AppUpdateDownloadCancelledException implements Exception {
  const AppUpdateDownloadCancelledException();

  @override
  String toString() => 'App update download was cancelled by the user.';
}

class DioAppUpdateHttpClient implements AppUpdateHttpClient {
  const DioAppUpdateHttpClient();

  Future<void> _cancelTunnelRequest(String requestId) async {
    // The cancellation action can overtake request registration in the Go
    // executor. Retry briefly so an immediate user cancel is not lost.
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
    if (response.statusCode != 200 || data == null) {
      throw StateError('Unable to read `$url`.');
    }
    return data;
  }

  @override
  Future<String?> readText(String url) async {
    final response = await request.getTextResponseForUrl(url);
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
    this.packageInstaller = const MethodChannelAndroidPackageInstaller(),
  });

  final AppUpdateManifestVerifier manifestVerifier;
  final AppUpdateManifestRollbackGuard rollbackGuard;
  final AppUpdateHttpClient httpClient;
  final AndroidPackageInstaller packageInstaller;

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

    final installedVersionCode = int.tryParse(
      globalState.packageInfo.buildNumber,
    );
    final hasUpdate = release.versionCode != null && installedVersionCode != null
        ? release.versionCode! > installedVersionCode
        : utils.compareVersions(
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
    final model = ValueNotifier<_UpdateDialogModel>(
      const _UpdateDialogModel.prompt(),
    );
    final action = Completer<AppUpdatePromptAction?>();
    var closed = false;
    NavigatorState? navigator;

    final dialogFuture = globalState.showCommonDialog<void>(
      child: Builder(
        builder: (context) {
          navigator ??= Navigator.of(context);
          return _AppUpdateDialog(
            release: release,
            submits: submits,
            model: model,
            onAction: (value) {
              if (action.isCompleted) {
                return;
              }
              action.complete(value);
              // На загрузку окно не закрываем — оно превращается
              // в прогресс, чтобы поток читался как одно действие.
              if (value != AppUpdatePromptAction.download && !closed) {
                navigator?.pop();
              }
            },
          );
        },
      ),
    );

    unawaited(dialogFuture.whenComplete(() {
      closed = true;
      if (!action.isCompleted) {
        action.complete(null);
      }
    }));

    final result = await action.future;
    if (result == AppUpdatePromptAction.download && !closed) {
      _activeUpdateDialog = _ActiveUpdateDialog(
        release: release,
        model: model,
        navigator: navigator,
        closed: dialogFuture,
      );
    } else {
      model.dispose();
    }
    return result;
  }

  @visibleForTesting
  @override
  Future<void> showUpdateCheckError() async {
    // Отчёт без выбора: окно с «Отменой» тут ничего не спрашивает.
    globalState.showNotifier(appLocalizations.checkUpdateError);
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
        if (target.existsSync()) {
          target.deleteSync();
        }
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
        if (target.existsSync()) {
          target.deleteSync();
        }
        // Отмену нельзя лечить следующим зеркалом — она осознанная.
        if (cancellation?.isCancelled ?? false) {
          throw const AppUpdateDownloadCancelledException();
        }
        lastError = error;
        commonPrint.log('Failed to download app update mirror `$url`: $error');
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
      AppUpdateDownloadCancellation cancellation,
    ) downloadTask,
  }) async {
    final cancellation = AppUpdateDownloadCancellation();
    // Окно с описанием версии остаётся на экране и превращается в прогресс.
    // Отдельный диалог открываем только если превращать нечего.
    final active = _activeUpdateDialog;
    _activeUpdateDialog = null;
    final reuse = active != null && active.release.tagName == release.tagName;

    final model = reuse
        ? active.model
        : ValueNotifier<_UpdateDialogModel>(const _UpdateDialogModel.prompt());
    var navigator = reuse ? active.navigator : null;
    var closed = false;

    void publish(_DownloadProgress value) {
      model.value = _UpdateDialogModel.downloading(
        asset: asset,
        progress: value,
        onCancel: cancellation.cancel,
      );
    }

    publish(const _DownloadProgress(received: 0, total: 0));

    final Future<void> dialogFuture;
    if (reuse) {
      dialogFuture = active.closed;
    } else {
      dialogFuture = globalState.showCommonDialog<void>(
        dismissible: false,
        child: Builder(
          builder: (context) {
            navigator ??= Navigator.of(context);
            return _AppUpdateDialog(
              release: release,
              submits: const [],
              model: model,
              onAction: (_) {},
            );
          },
        ),
      );
    }
    unawaited(dialogFuture.whenComplete(() => closed = true));

    void closeDialog() {
      if (!closed && (navigator?.canPop() ?? false)) {
        navigator?.pop();
      }
    }

    try {
      await Future<void>.delayed(Duration.zero);
      final stopwatch = Stopwatch()..start();
      final result = await downloadTask((received, total) {
        publish(
          _DownloadProgress(
            received: received,
            total: total,
            elapsed: stopwatch.elapsed,
          ),
        );
      }, cancellation);
      closeDialog();
      await dialogFuture;
      return result;
    } catch (_) {
      closeDialog();
      await dialogFuture;
      rethrow;
    } finally {
      model.dispose();
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
      packageInstaller.install(path);
}

/// Состояние окна апдейтера: одно и то же окно сначала описывает версию,
/// затем превращается в прогресс загрузки.
class _UpdateDialogModel {
  const _UpdateDialogModel.prompt()
      : asset = null,
        progress = null,
        onCancel = null;

  const _UpdateDialogModel.downloading({
    required ReleaseAsset this.asset,
    required _DownloadProgress this.progress,
    required VoidCallback this.onCancel,
  });

  final ReleaseAsset? asset;
  final _DownloadProgress? progress;
  final VoidCallback? onCancel;

  bool get isDownloading => asset != null;
}

/// Ссылка на уже открытое окно апдейтера, чтобы фаза загрузки не открывала
/// второе окно поверх первого.
class _ActiveUpdateDialog {
  const _ActiveUpdateDialog({
    required this.release,
    required this.model,
    required this.navigator,
    required this.closed,
  });

  final AppRelease release;
  final ValueNotifier<_UpdateDialogModel> model;
  final NavigatorState? navigator;
  final Future<void> closed;
}

// null здесь значимо: «открытого окна апдейтера нет», поэтому не late.
// ignore: use_late_for_private_fields_and_variables
_ActiveUpdateDialog? _activeUpdateDialog;

class _AppUpdateDialog extends StatelessWidget {
  const _AppUpdateDialog({
    required this.release,
    required this.submits,
    required this.model,
    required this.onAction,
  });

  final AppRelease release;
  final List<String> submits;
  final ValueNotifier<_UpdateDialogModel> model;
  final ValueChanged<AppUpdatePromptAction> onAction;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<_UpdateDialogModel>(
        valueListenable: model,
        builder: (context, value, _) => CommonDialog(
          title: value.isDownloading
              ? '${appLocalizations.downloadUpdate} ${release.tagName}'
              : '${appLocalizations.discoverNewVersion} ${release.tagName}',
          overrideScroll: value.isDownloading,
          actions: [
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child:
                  value.isDownloading ? _cancelAction(value) : _promptActions(),
            ),
          ],
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: value.isDownloading
                  ? _downloadBody(context, value)
                  : _promptBody(context),
            ),
          ),
        ),
      );

  Widget _promptActions() =>
      // Главное действие занимает всю ширину, второстепенные делят строку
      // поровну: в узком диалоге ряд из трёх кнопок разной длины даёт
      // слишком мелкие цели для нажатия.
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => onAction(AppUpdatePromptAction.download),
              child: Text(appLocalizations.goDownload),
            ),
          ),
          const SizedBox(height: 8),
          // Столбик, а не ряд: подписи в разных языках имеют разную длину,
          // и делёж строки пополам ломает выравнивание.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => onAction(AppUpdatePromptAction.later),
              child: Text(appLocalizations.later),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => onAction(AppUpdatePromptAction.skip),
              child: Text(appLocalizations.skipVersion),
            ),
          ),
        ],
      );

  Widget _cancelAction(_UpdateDialogModel value) => SizedBox(
        width: double.infinity,
        // Окно закрывает сам поток загрузки, когда задача упадёт с отменой:
        // иначе кнопка сняла бы маршрут раньше и pop ушёл бы не туда.
        child: OutlinedButton(
          onPressed: value.onCancel,
          child: Text(appLocalizations.cancel),
        ),
      );

  Widget _promptBody(BuildContext context) => SelectionArea(
        key: const ValueKey('prompt'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (release.prerelease) ...[
              _preReleaseChip(context),
              const SizedBox(height: 16),
            ],
            for (final submit in submits)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.check,
                        size: 16,
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(submit, style: _updateBodyStyle(context)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _downloadBody(BuildContext context, _UpdateDialogModel value) {
    final bodyStyle = _updateBodyStyle(context);
    final mutedStyle = bodyStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final asset = value.asset!;
    final progress = value.progress!;
    final fraction = progress.fraction;
    return Column(
      key: const ValueKey('download'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (release.prerelease) ...[
          _preReleaseChip(context),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Icon(
              Icons.download,
              size: 16,
              color: context.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                asset.androidAbi ?? asset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mutedStyle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: fraction, minHeight: 6),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              fraction == null
                  ? appLocalizations.preparing
                  : '${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
              style: bodyStyle,
            ),
            Text(progress.sizeText, style: mutedStyle),
          ],
        ),
        Text(progress.speedText, style: mutedStyle),
      ],
    );
  }
}

/// Общая типографика обоих окон апдейтера: они должны читаться как один поток.
TextStyle _updateBodyStyle(BuildContext context) =>
    (Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14))
        .copyWith(height: 1.4);

/// Метка, а не действие: CommonChip построен на ActionChip и всегда
/// откликается на нажатие.
Widget _preReleaseChip(BuildContext context) => Chip(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      clipBehavior: Clip.antiAlias,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      side: BorderSide(color: Theme.of(context).dividerColor.opacity15),
      labelStyle: Theme.of(context).textTheme.bodyMedium,
      label: Text(appLocalizations.preReleaseLabel),
    );

class _DownloadProgress {
  const _DownloadProgress({
    required this.received,
    required this.total,
    this.elapsed = Duration.zero,
  });

  final int received;
  final int total;
  final Duration elapsed;

  /// Средняя скорость за всю загрузку: она заметно спокойнее мгновенной
  /// и не дёргает подпись на каждом кадре. Значение есть с первого кадра —
  /// подпись, появляющаяся не сразу, читается как рывок вёрстки. Нижняя
  /// граница знаменателя гасит бессмысленно большие числа на старте.
  String get speedText {
    final milliseconds =
        elapsed.inMilliseconds < 200 ? 200 : elapsed.inMilliseconds;
    final bytesPerSecond =
        received <= 0 ? 0 : (received / (milliseconds / 1000)).round();
    return '${_formatBytes(bytesPerSecond)}/s';
  }

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
