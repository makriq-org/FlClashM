import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';

import '../../common/common.dart';
import '../../state.dart';
import '../../widgets/dialog.dart';
import 'app_update_manifest.dart';
import 'app_update_platform_bridge.dart';
import 'app_update_release.dart';
import 'app_update_service.dart';
import 'desktop_update_catalog.dart';
import 'desktop_update_rollback.dart';

class DesktopUpdateEnvironment {
  const DesktopUpdateEnvironment({
    required this.target,
    required this.packageManagedLinux,
  });

  factory DesktopUpdateEnvironment.current() =>
      DesktopUpdateEnvironment.forOperatingSystem(
        Platform.operatingSystem,
        packageManagedLinux:
            Platform.environment['APPIMAGE']?.trim().isEmpty ?? true,
      );

  factory DesktopUpdateEnvironment.forOperatingSystem(
    String rawOperatingSystem, {
    DesktopUpdateArchitecture? architecture,
    bool packageManagedLinux = false,
  }) {
    final operatingSystem = switch (rawOperatingSystem) {
      'linux' => DesktopUpdateOperatingSystem.linux,
      'windows' => DesktopUpdateOperatingSystem.windows,
      'macos' => DesktopUpdateOperatingSystem.macos,
      _ => throw UnsupportedError(
          'Desktop updates do not support `${Platform.operatingSystem}`.',
        ),
    };
    final resolvedArchitecture = architecture ??
        switch (Abi.current()) {
          Abi.linuxX64 ||
          Abi.windowsX64 ||
          Abi.macosX64 =>
            DesktopUpdateArchitecture.x64,
          Abi.macosArm64 => DesktopUpdateArchitecture.arm64,
          _ => throw UnsupportedError(
              'Desktop updates do not support `${Abi.current()}`.',
            ),
        };
    final packageKind = switch (operatingSystem) {
      DesktopUpdateOperatingSystem.linux => DesktopPackageKind.appImage,
      DesktopUpdateOperatingSystem.windows =>
        DesktopPackageKind.windowsInstaller,
      DesktopUpdateOperatingSystem.macos => DesktopPackageKind.macosAppArchive,
    };
    return DesktopUpdateEnvironment(
      target: DesktopUpdateTarget(
        operatingSystem: operatingSystem,
        architecture: resolvedArchitecture,
        packageKind: packageKind,
      ),
      packageManagedLinux:
          operatingSystem == DesktopUpdateOperatingSystem.linux &&
              packageManagedLinux,
    );
  }

  final DesktopUpdateTarget target;
  final bool packageManagedLinux;
}

abstract interface class DesktopInstallHandoff {
  Future<bool> installVerifiedPackage({
    required String packagePath,
    required DesktopUpdateTarget target,
  });
}

/// PR 6-8 replace this boundary with the native installer implementations.
/// Keeping a typed handoff here prevents a verified package from being passed
/// to a shell or to a platform with the wrong package semantics.
class DeferredDesktopInstallHandoff implements DesktopInstallHandoff {
  const DeferredDesktopInstallHandoff();

  @override
  Future<bool> installVerifiedPackage({
    required String packagePath,
    required DesktopUpdateTarget target,
  }) =>
      Future.error(
        UnsupportedError(switch (target.packageKind) {
          DesktopPackageKind.windowsInstaller =>
            'The verified Windows installer is ready; native installer handoff is unavailable.',
          DesktopPackageKind.macosAppArchive =>
            'The verified macOS app replacement is ready; native replacement handoff is unavailable.',
          DesktopPackageKind.appImage =>
            'The verified AppImage replacement is ready; native replacement handoff is unavailable.',
        }),
      );
}

class DesktopAppUpdatePackageSelector implements AppUpdatePackageSelector {
  const DesktopAppUpdatePackageSelector({required this.environment});

  final DesktopUpdateEnvironment environment;

  @override
  Future<AppUpdatePackage> select({
    required AppRelease release,
    required AppUpdatePlatformBridge platform,
  }) async {
    if (environment.packageManagedLinux) {
      throw StateError(
        'This Linux installation is managed by a package manager. '
        'Use the signed release page or your configured package repository.',
      );
    }
    if (release.assets.length != 1) {
      throw const FormatException(
        'Desktop update release does not contain one selected package.',
      );
    }
    final asset = release.assets.single;
    final digest = asset.sha256Digest;
    if (digest == null) {
      throw const FormatException(
        'Desktop update package has no signed SHA256 digest.',
      );
    }
    return AppUpdatePackage(asset: asset, sha256: digest);
  }
}

class DesktopAppUpdateBridge extends BaseAppUpdatePlatformBridge {
  const DesktopAppUpdateBridge({
    required this.environment,
    this.catalogVerifier = const DesktopUpdateCatalogVerifier(),
    this.desktopRollbackGuard =
        const SharedPreferencesDesktopUpdateRollbackGuard(),
    this.installHandoff = const DeferredDesktopInstallHandoff(),
    super.httpClient,
  });

  final DesktopUpdateEnvironment environment;
  final DesktopUpdateCatalogVerifier catalogVerifier;
  final DesktopUpdateRollbackGuard desktopRollbackGuard;
  final DesktopInstallHandoff installHandoff;

  @override
  String get latestReleaseUrl => '$sourceForgeProjectUrl/files/releases/';

  @override
  Future<AppRelease?> checkForAppUpdate({
    required bool includePrerelease,
    required String skippedTagName,
  }) async {
    final channels = <AppUpdateChannel>[
      AppUpdateChannel.stable,
      if (includePrerelease) AppUpdateChannel.prerelease,
    ];
    final candidates = <AppRelease>[];
    for (final channel in channels) {
      try {
        final catalogBytes = await httpClient.readBytes(
          desktopUpdateCatalogUrl(channel),
        );
        final signatureBytes = await httpClient.readBytes(
          desktopUpdateCatalogSignatureUrl(channel),
        );
        final catalog = await catalogVerifier.verifyAndDecode(
          catalogBytes: catalogBytes,
          signatureBytes: signatureBytes,
          expectedChannel: channel,
        );
        final selectedAsset = catalog.select(environment.target);
        await desktopRollbackGuard.validateAndRecord(catalog);
        final release = catalog.toRelease();
        candidates.add(
          AppRelease(
            tagName: release.tagName,
            body: release.body,
            htmlUrl: release.htmlUrl,
            assets: [selectedAsset.toReleaseAsset()],
            prerelease: release.prerelease,
            draft: false,
            versionCode: catalog.versionCode,
            catalogId: catalog.catalogId,
          ),
        );
      } catch (error) {
        commonPrint.log(
          'Failed to read signed ${channel.wireName} desktop update catalog: '
          '$error',
        );
      }
    }
    AppRelease? latest;
    for (final release in candidates) {
      if (latest == null ||
          (release.versionCode ?? 0) > (latest.versionCode ?? 0)) {
        latest = release;
      }
    }
    if (latest == null || latest.tagName == skippedTagName.trim()) {
      return null;
    }
    final currentVersionCode =
        int.tryParse(globalState.packageInfo.buildNumber) ?? 0;
    return (latest.versionCode ?? 0) > currentVersionCode ? latest : null;
  }

  @override
  Future<List<String>> readSupportedAbis() async => const [];

  @override
  Future<AppUpdatePromptAction?> promptForUpdateDownload({
    required AppRelease release,
    required List<String> submits,
  }) async {
    final accepted = await globalState.showMessage(
      title: appLocalizations.update,
      message: TextSpan(text: submits.join('\n')),
      confirmText: appLocalizations.download,
    );
    return (accepted ?? false)
        ? AppUpdatePromptAction.download
        : AppUpdatePromptAction.later;
  }

  @override
  Future<void> showUpdateCheckError() async {
    globalState.showNotifier(appLocalizations.checkUpdateError);
  }

  @override
  Future<void> showUpdateInstallError({
    required String message,
    required String releaseUrl,
  }) async {
    final openRelease = await globalState.showMessage(
      title: appLocalizations.update,
      message: TextSpan(text: message),
      confirmText: appLocalizations.goDownload,
    );
    if (openRelease ?? false) await openReleasePage(releaseUrl);
  }

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
    final progress = ValueNotifier<(int, int)>((0, asset.size));
    NavigatorState? navigator;
    var closed = false;
    final dialog = globalState.showCommonDialog<void>(
      dismissible: false,
      child: Builder(
        builder: (context) {
          navigator ??= Navigator.of(context);
          return _DesktopUpdateDownloadDialog(
            release: release,
            progress: progress,
            onCancel: cancellation.cancel,
          );
        },
      ),
    );
    unawaited(dialog.whenComplete(() => closed = true));
    try {
      await Future<void>.delayed(Duration.zero);
      return await downloadTask(
        (received, total) => progress.value = (received, total),
        cancellation,
      );
    } finally {
      if (!closed && (navigator?.canPop() ?? false)) navigator?.pop();
      await dialog;
      progress.dispose();
    }
  }

  @override
  Future<void> prepareInstallHandoff() async {}

  @override
  Future<bool> installPackage(String path) {
    if (environment.packageManagedLinux) {
      return Future.error(
        StateError(
          'Package-managed Linux installations must be updated through the '
          'configured repository.',
        ),
      );
    }
    return installHandoff.installVerifiedPackage(
      packagePath: path,
      target: environment.target,
    );
  }
}

class _DesktopUpdateDownloadDialog extends StatelessWidget {
  const _DesktopUpdateDownloadDialog({
    required this.release,
    required this.progress,
    required this.onCancel,
  });

  final AppRelease release;
  final ValueNotifier<(int, int)> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<(int, int)>(
        valueListenable: progress,
        builder: (context, value, _) {
          final total = value.$2 > 0 ? value.$2 : 0;
          final fraction = total > 0 ? value.$1 / total : null;
          return CommonDialog(
            title: '${appLocalizations.downloadUpdate} ${release.tagName}',
            actions: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: Text(appLocalizations.cancel),
                ),
              ),
            ],
            child: LinearProgressIndicator(value: fraction?.clamp(0, 1)),
          );
        },
      );
}
