import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../state.dart';
import '../../ui/context.dart';
import '../../widgets/dialog.dart';
import '../backend/backend.dart';
import '../services/app_update_http.dart';
import '../services/app_update_identity.dart';
import '../services/app_update_install_journal.dart';
import '../services/app_update_manifest.dart';
import '../services/app_update_manifest_release.dart';
import '../services/app_update_manifest_rollback.dart';
import '../services/app_update_mirrors.dart';
import '../services/app_update_release.dart';
import '../services/app_update_session.dart';
import 'android_package_inspector.dart';
import 'android_package_installer.dart';

/// HTTP-слой апдейтера. Подписанные документы читаются одним запросом за шаг:
/// редиректы разбирает `fetchAppUpdateDocument`, поэтому каждый адрес цепочки
/// проверяется отдельно.
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
  Future<AppUpdateHttpResponse> open(
    Uri url, {
    required int maxBytes,
    required Duration deadline,
  }) async {
    final response = await request.getBoundedResponseForUrl(
      url.toString(),
      maxBytes: maxBytes,
      timeout: deadline,
    );
    final statusCode = response.statusCode ?? 0;
    final location = response.headers.value(HttpHeaders.locationHeader);
    return AppUpdateHttpResponse(
      statusCode: statusCode,
      location: location == null ? null : Uri.tryParse(location),
      body: statusCode == HttpStatus.ok
          ? response.data ?? Uint8List(0)
          : Uint8List(0),
    );
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
    final cancelToken = CancelToken();
    final throughTunnel = globalState.isStart;
    final removeCancellationListener = cancellation?.addListener(() {
      cancelToken.cancel();
      if (throughTunnel) {
        unawaited(_cancelTunnelRequest(requestId));
      }
    });
    try {
      await request.downloadFileForUrl(
        url,
        targetPath,
        onProgress: onReceiveProgress,
        requestId: requestId,
        expectedLength: expectedLength,
        cancelToken: cancelToken,
      );
    } catch (_) {
      if (cancellation?.isCancelled ?? false) {
        throw const AppUpdateDownloadCancelledException();
      }
      rethrow;
    } finally {
      removeCancellationListener?.call();
    }
    if (cancellation?.isCancelled ?? false) {
      throw const AppUpdateDownloadCancelledException();
    }
  }
}

/// Итог окна обновления: пропуск версии запоминается, «позже» и закрытие —
/// просто отказ от установки сейчас.
enum AppUpdateWindowResult { later, skip }

abstract interface class AppUpdatePlatformBridge implements AppUpdateInstaller {
  String get latestReleaseUrl;

  AppUpdateInstallJournal get installJournal;

  Future<AppRelease?> checkForAppUpdate({
    required bool includePrerelease,
    required String skippedTagName,
  });

  /// Показывает окно обновления и ведёт его по [session]. Загрузка и установка
  /// запускаются только действиями пользователя внутри окна.
  Future<AppUpdateWindowResult?> showUpdateWindow({
    required AppRelease release,
    required List<String> submits,
    required AppUpdateSession session,
  });

  Future<void> showUpdateCheckError();

  Future<bool> openReleasePage(String url);

  /// Удаляет скачанные APK, когда установленная сборка подтверждает успешное
  /// обновление. До подтверждения файлы остаются для повтора.
  Future<void> pruneInstalledUpdates();
}

class AndroidUpdateBridge implements AppUpdatePlatformBridge {
  const AndroidUpdateBridge({
    this.manifestVerifier = const AppUpdateManifestVerifier(),
    this.rollbackGuard =
        const SharedPreferencesAppUpdateManifestRollbackGuard(),
    this.httpClient = const DioAppUpdateHttpClient(),
    this.packageInstaller = const MethodChannelAndroidPackageInstaller(),
    this.packageInspector = const MethodChannelAndroidPackageInspector(),
    this.mirrorSource = const ProfileAppUpdateMirrors(),
    this.installJournal = const SharedPreferencesAppUpdateInstallJournal(),
    this.now = _utcNow,
  });

  final AppUpdateManifestVerifier manifestVerifier;
  final AppUpdateManifestRollbackGuard rollbackGuard;
  final AppUpdateHttpClient httpClient;
  final AndroidPackageInstaller packageInstaller;
  final AndroidPackageInspector packageInspector;
  final AppUpdateMirrorSource mirrorSource;

  @override
  final AppUpdateInstallJournal installJournal;

  /// Часы для проверки свежести каталога: тесты подставляют своё время.
  final DateTime Function() now;

  @override
  String get latestReleaseUrl => '$sourceForgeProjectUrl/files/releases/';

  @override
  Future<AppRelease?> checkForAppUpdate({
    required bool includePrerelease,
    required String skippedTagName,
  }) async {
    final mirrors = mirrorSource.read();
    final signed = await _readSignedCatalogs(
      includePrerelease: includePrerelease,
      mirrors: mirrors,
    );
    final availableReleases = <AppRelease>[
      ...signed.releases,
      if (!signed.complete)
        ...await _readGitHubReleases(includePrerelease: includePrerelease),
    ];

    // Ответ снят для прежнего профиля: его решение не переносится на новый.
    if (!mirrorSource.read().sameDecisionContextAs(mirrors)) {
      commonPrint.log(
        'Discarded an app update answer that belongs to a previous profile.',
      );
      return null;
    }

    final installedVersionCode = int.tryParse(
      globalState.packageInfo.buildNumber,
    );
    final installedVersionName = globalState.packageInfo.version;
    final supportedAbis = await readSupportedAbis();
    if (!mirrorSource.read().sameDecisionContextAs(mirrors)) {
      return null;
    }
    final eligible = availableReleases.where(
      (release) =>
          selectAndroidReleaseAsset(release, supportedAbis: supportedAbis) !=
              null &&
          isAppReleaseUpdateAvailable(
            release,
            installedVersionCode: installedVersionCode,
            installedVersionName: installedVersionName,
            supportedAbis: supportedAbis,
          ),
    );
    final required = selectLatestAppRelease(
      eligible.where(
        (release) => isAppUpdateRequired(
          release,
          installedVersionCode: installedVersionCode,
          installedVersionName: installedVersionName,
        ),
      ),
      includePrerelease: includePrerelease,
    );
    if (required != null) {
      return required;
    }
    final optional = selectLatestAppRelease(
      eligible,
      includePrerelease: includePrerelease,
    );
    return optional?.tagName == skippedTagName.trim() ? null : optional;
  }

  /// Официальный каталог и зеркало профиля проверяются одинаково: подпись
  /// ключом FlClashM, канал и защита от понижения. Зеркало — только транспорт.
  Future<({List<AppRelease> releases, bool complete})> _readSignedCatalogs({
    required bool includePrerelease,
    required AppUpdateMirrorSnapshot mirrors,
  }) async {
    final channels = <AppUpdateChannel>[
      AppUpdateChannel.stable,
      if (includePrerelease) AppUpdateChannel.prerelease,
    ];
    final releases = <AppRelease>[];
    var complete = true;
    final moment = now();
    for (final channel in channels) {
      AppUpdateManifest? latest;
      final sources = <(String, Uri)>[
        ('official', Uri.parse(appUpdateManifestUrl(channel))),
        if (mirrors.manifestFor(channel) case final mirror?)
          ('profile mirror', mirror),
      ];
      for (final (label, url) in sources) {
        try {
          final manifest = await _readSignedManifest(url, channel: channel);
          if (latest == null ||
              manifest.versionCode > latest.versionCode ||
              (manifest.versionCode == latest.versionCode &&
                  manifest.publishedAt.isAfter(latest.publishedAt))) {
            latest = manifest;
          }
        } catch (error) {
          commonPrint.log(
            'Failed to read the signed ${channel.wireName} app update '
            'catalog from the $label source: $error',
          );
        }
      }
      if (!mirrorSource.read().sameDecisionContextAs(mirrors)) {
        return (releases: <AppRelease>[], complete: true);
      }
      if (latest == null) {
        complete = false;
        continue;
      }
      try {
        await rollbackGuard.validateAndRecord(latest);
        releases.add(latest.toRelease(now: moment));
      } catch (error) {
        complete = false;
        commonPrint.log(
          'Rejected ${channel.wireName} app update catalog: $error',
        );
      }
    }
    return (releases: releases, complete: complete);
  }

  Future<AppUpdateManifest> _readSignedManifest(
    Uri manifestUrl, {
    required AppUpdateChannel channel,
  }) async {
    final manifestBytes = await fetchAppUpdateDocument(
      httpClient,
      manifestUrl,
      maxBytes: appUpdateManifestMaxBytes,
    );
    final signatureBytes = await fetchAppUpdateDocument(
      httpClient,
      appUpdateSignatureUriOf(manifestUrl),
      maxBytes: appUpdateSignatureMaxBytes,
    );
    if (signatureBytes.length != 64) {
      throw const FormatException('Invalid app update signature size.');
    }
    return manifestVerifier.verifyAndDecode(
      manifestBytes: manifestBytes,
      signatureBytes: signatureBytes,
      expectedChannel: channel,
    );
  }

  Future<List<AppRelease>> _readGitHubReleases({
    required bool includePrerelease,
  }) async {
    try {
      final data = await httpClient.readJsonList(
        'https://api.github.com/repos/$repository/releases?per_page=20',
      );
      final releases = <AppRelease>[];
      var hasStable = false;
      var hasPrerelease = false;
      // GitHub returns releases newest first. Only the current candidate for
      // each enabled channel needs its metadata sidecar fetched.
      for (final item in data.whereType<Map>()) {
        var release = AppRelease.fromJson(Map<String, dynamic>.from(item));
        if (release.draft ||
            (release.prerelease && !includePrerelease) ||
            (release.prerelease ? hasPrerelease : hasStable)) {
          continue;
        }
        if (release.prerelease) {
          hasPrerelease = true;
        } else {
          hasStable = true;
        }
        ReleaseAsset? metadataAsset;
        for (final asset in release.assets) {
          if (asset.name == 'FlClashM-android-release-metadata.json') {
            metadataAsset = asset;
            break;
          }
        }
        if (metadataAsset != null) {
          try {
            final metadata = await httpClient.readText(
              metadataAsset.browserDownloadUrl,
            );
            if (metadata != null) {
              release = applyAppReleaseMetadata(release, metadata);
            }
          } catch (error) {
            commonPrint.log(
              'Failed to read GitHub release metadata for '
              '${release.tagName}: $error',
            );
          }
        }
        releases.add(release);
        if (hasStable && (!includePrerelease || hasPrerelease)) {
          break;
        }
      }
      return releases;
    } catch (error) {
      commonPrint.log('Failed to read GitHub app releases: $error');
      return const [];
    }
  }

  @visibleForTesting
  @override
  Future<AppUpdateWindowResult?> showUpdateWindow({
    required AppRelease release,
    required List<String> submits,
    required AppUpdateSession session,
  }) async {
    final result = Completer<AppUpdateWindowResult?>();
    NavigatorState? navigator;
    var closed = false;

    final dialogFuture = globalState.showCommonDialog<void>(
      dismissible: false,
      child: Builder(
        builder: (context) {
          navigator ??= Navigator.of(context);
          return _AppUpdateDialog(
            release: release,
            submits: submits,
            session: session,
            onOpenReleasePage: () => openReleasePage(
              release.htmlUrl.isNotEmpty ? release.htmlUrl : latestReleaseUrl,
            ),
            onClose: (value) {
              if (result.isCompleted) {
                return;
              }
              result.complete(value);
              if (!closed && (navigator?.canPop() ?? false)) {
                navigator?.pop();
              }
            },
          );
        },
      ),
    );

    unawaited(
      dialogFuture.whenComplete(() {
        closed = true;
        if (!result.isCompleted) {
          result.complete(null);
        }
      }),
    );

    return result.future;
  }

  @visibleForTesting
  @override
  Future<void> showUpdateCheckError() async {
    // Отчёт без выбора: окно с «Отменой» тут ничего не спрашивает.
    globalState.showNotifier(appLocalizations.checkUpdateError);
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
    if (asset.size > appUpdateMaxApkBytes) {
      throw StateError(
        'APK `${asset.name}` is larger than the updater accepts.',
      );
    }
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
        // Размер из подписанного каталога — вторая граница после хеша.
        if (asset.size > 0 && target.lengthSync() != asset.size) {
          throw StateError('Unexpected APK size from mirror `$url`.');
        }
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

  @override
  Future<String> getUpdateDirectoryPath() async {
    final homeDir = await appPath.homeDirPath;
    final directory = Directory(path.join(homeDir, 'updates'));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<AppUpdatePackageIdentity?> inspectInstalledPackage() async =>
      packageInspector.inspectInstalled();

  @override
  Future<AppUpdatePackageIdentity?> inspectPackage(String path) async =>
      packageInspector.inspectApk(path);

  @override
  Future<void> prepareInstallHandoff() async {
    if (!Platform.isAndroid) {
      return;
    }

    await backendClient.command('runtime.stop');
  }

  @visibleForTesting
  @override
  Future<bool> openReleasePage(String url) => launchUrl(Uri.parse(url));

  @override
  Future<bool> installPackage(String path) async =>
      packageInstaller.install(path);

  @override
  Future<void> pruneInstalledUpdates() async {
    final preparedVersionCode = await installJournal.readPreparedVersionCode();
    final installedVersionCode = int.tryParse(
      globalState.packageInfo.buildNumber,
    );
    if (!isPreparedAppUpdateInstalled(
      preparedVersionCode: preparedVersionCode,
      installedVersionCode: installedVersionCode,
    )) {
      return;
    }
    final directory = Directory(await getUpdateDirectoryPath());
    if (directory.existsSync()) {
      for (final entity in directory.listSync(followLinks: false)) {
        try {
          entity.deleteSync(recursive: true);
        } on FileSystemException catch (error) {
          commonPrint.log('Failed to delete stale app update: $error');
        }
      }
    }
    await installJournal.clear();
  }
}

DateTime _utcNow() => DateTime.now().toUtc();

/// Окно обновления: описание версии, загрузка/проверка, явная кнопка
/// «Установить» и повтор после сбоя. Установщик не открывается сам.
class _AppUpdateDialog extends StatelessWidget {
  const _AppUpdateDialog({
    required this.release,
    required this.submits,
    required this.session,
    required this.onOpenReleasePage,
    required this.onClose,
  });

  final AppRelease release;
  final List<String> submits;
  final AppUpdateSession session;
  final VoidCallback onOpenReleasePage;
  final ValueChanged<AppUpdateWindowResult> onClose;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final phase = session.phase;
      return PopScope(
        canPop: !session.isBusy,
        child: CommonDialog(
          title: phase == AppUpdatePhase.prompt
              ? '${appLocalizations.discoverNewVersion} ${release.tagName}'
              : '${appLocalizations.downloadUpdate} ${release.tagName}',
          overrideScroll: phase != AppUpdatePhase.prompt,
          actions: _actions(context, phase),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _body(context, phase),
            ),
          ),
        ),
      );
    },
  );

  List<Widget> _actions(BuildContext context, AppUpdatePhase phase) {
    final close = OutlinedButton(
      onPressed: () => onClose(AppUpdateWindowResult.later),
      child: Text(appLocalizations.close),
    );
    if (session.isBusy) {
      if (phase == AppUpdatePhase.installing) {
        return const [];
      }
      return [
        OutlinedButton(
          onPressed: session.cancel,
          child: Text(appLocalizations.cancel),
        ),
      ];
    }
    switch (phase) {
      case AppUpdatePhase.prompt:
        return [
          if (session.failure != null) ...[
            close,
            FilledButton(
              onPressed: session.retry,
              child: Text(appLocalizations.retry),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: session.download,
                child: Text(appLocalizations.goDownload),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => onClose(AppUpdateWindowResult.later),
                child: Text(appLocalizations.later),
              ),
            ),
            if (!session.requiredUpdate) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => onClose(AppUpdateWindowResult.skip),
                  child: Text(appLocalizations.skipVersion),
                ),
              ),
            ],
          ],
        ];
      case AppUpdatePhase.ready:
        return [
          close,
          FilledButton(
            onPressed: session.canInstall ? session.install : null,
            child: Text(appLocalizations.updateInstall),
          ),
        ];
      case AppUpdatePhase.downloading:
      case AppUpdatePhase.verifying:
      case AppUpdatePhase.installing:
        return const [];
    }
  }

  Widget _body(BuildContext context, AppUpdatePhase phase) => switch (phase) {
    AppUpdatePhase.prompt => _promptBody(context),
    AppUpdatePhase.downloading => _downloadBody(context),
    AppUpdatePhase.verifying => _verifyingBody(context),
    AppUpdatePhase.installing => _installingBody(context),
    AppUpdatePhase.ready => _readyBody(context),
  };

  Widget _promptBody(BuildContext context) {
    final failure = session.failure;
    return SelectionArea(
      key: const ValueKey('prompt'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session.requiredUpdate) ...[
            Text(
              appLocalizations.updateRequired,
              style: _updateBodyStyle(context)
                  .copyWith(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 16),
          ],
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
          if (failure != null) _failureBlock(context, failure),
        ],
      ),
    );
  }

  Widget _downloadBody(BuildContext context) {
    final bodyStyle = _updateBodyStyle(context);
    final mutedStyle = bodyStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final total = session.total;
    final fraction = total > 0 ? session.received / total : null;
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
                session.asset?.apkAsset.name ?? release.tagName,
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
            Text(_sizeText(session.received, total), style: mutedStyle),
          ],
        ),
        Text(_speedText(session.received, session.elapsed), style: mutedStyle),
      ],
    );
  }

  Widget _verifyingBody(BuildContext context) => Column(
    key: const ValueKey('verifying'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const LinearProgressIndicator(minHeight: 6),
      const SizedBox(height: 12),
      Text(appLocalizations.updateVerifying, style: _updateBodyStyle(context)),
    ],
  );

  Widget _installingBody(BuildContext context) => Column(
    key: const ValueKey('installing'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const LinearProgressIndicator(minHeight: 6),
      const SizedBox(height: 12),
      Text(appLocalizations.preparing, style: _updateBodyStyle(context)),
    ],
  );

  Widget _readyBody(BuildContext context) {
    final bodyStyle = _updateBodyStyle(context);
    final mutedStyle = bodyStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final prepared = session.prepared;
    final identity = prepared?.identity;
    return Column(
      key: const ValueKey('ready'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.verified_outlined,
              size: 16,
              color: context.colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(appLocalizations.updateVerified, style: bodyStyle),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (prepared != null)
          _verifiedRow(
            context,
            'SHA-256',
            _shortDigest(prepared.sha256),
            mutedStyle,
          ),
        if (identity != null) ...[
          _verifiedRow(context, 'Package', identity.packageName, mutedStyle),
          _verifiedRow(
            context,
            'Signer',
            _shortDigest(identity.signerFingerprint),
            mutedStyle,
          ),
          _verifiedRow(
            context,
            'versionCode',
            '${identity.versionCode}',
            mutedStyle,
          ),
        ],
        if (session.handedOff) ...[
          const SizedBox(height: 12),
          Text(appLocalizations.updateHandoff, style: mutedStyle),
        ],
        if (session.failure case final failure?)
          _failureBlock(context, failure),
      ],
    );
  }

  Widget _verifiedRow(
    BuildContext context,
    String label,
    String value,
    TextStyle style,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 88, child: Text(label, style: style)),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    ),
  );

  Widget _failureBlock(BuildContext context, AppUpdateFailure failure) {
    final bodyStyle = _updateBodyStyle(context);
    final mutedStyle = bodyStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final detail = failure.detail;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            switch (failure.kind) {
              AppUpdateFailureKind.download =>
                appLocalizations.updateErrorDownload,
              AppUpdateFailureKind.verify => appLocalizations.updateErrorVerify,
              AppUpdateFailureKind.install =>
                appLocalizations.updateErrorInstall,
            },
            style: bodyStyle.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(detail, style: mutedStyle),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: onOpenReleasePage,
            child: Text(appLocalizations.goDownload),
          ),
        ],
      ),
    );
  }

  static String _shortDigest(String digest) =>
      digest.length <= 16 ? digest : '${digest.substring(0, 16)}…';

  static String _sizeText(int received, int total) {
    if (total <= 0) {
      return _formatBytes(received);
    }
    return '${_formatBytes(received)} / ${_formatBytes(total)}';
  }

  /// Средняя скорость за всю загрузку: она спокойнее мгновенной и не дёргает
  /// подпись на каждом кадре. Нижняя граница знаменателя гасит большие числа
  /// на старте.
  static String _speedText(int received, Duration elapsed) {
    final milliseconds = elapsed.inMilliseconds < 200
        ? 200
        : elapsed.inMilliseconds;
    final bytesPerSecond = received <= 0
        ? 0
        : (received / (milliseconds / 1000)).round();
    return '${_formatBytes(bytesPerSecond)}/s';
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
  side: BorderSide(
    color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
  ),
  labelStyle: Theme.of(context).textTheme.bodyMedium,
  label: Text(appLocalizations.preReleaseLabel),
);
