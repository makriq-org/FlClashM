import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../enum/enum.dart';
import '../../models/models.dart';
import '../runtime/engine_manager.dart';
import '../services/product_shell_service.dart';
import '../services/runtime_access_platform.dart';

/// Capability that is intentionally absent until its platform PR lands.
enum DesktopCapability { tun, helper, updateInstallation }

String desktopCapabilityMessage(DesktopCapability capability) =>
    switch (capability) {
      DesktopCapability.tun =>
        'Desktop TUN is not implemented for this platform yet.',
      DesktopCapability.helper =>
        'Desktop privileged helper is not implemented for this platform yet.',
      DesktopCapability.updateInstallation =>
        'Desktop update installation is not implemented for this platform yet.',
    };

class DesktopRuntimeAccessPolicy implements RuntimeAccessPlatformBridge {
  const DesktopRuntimeAccessPolicy();

  @override
  bool get isAndroid => false;

  @override
  Future<List<Package>> readPackages() => Future.value(const []);

  @override
  Future<ImageProvider?> readPackageIcon(String packageName) =>
      Future.value(null);

  @override
  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  }) =>
      optionsJson;

  @override
  Future<ProfileAccessSnapshot> readAppliedProfileAccess() =>
      Future.value(const ProfileAccessSnapshot.available(null));

  @override
  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) {
    if (!requestedTunEnable) {
      onResolvedTunEnable(false);
      return Future.value(const ResolvedTunAccess.proceed(enableTun: false));
    }
    return Future.error(
      UnsupportedError(desktopCapabilityMessage(DesktopCapability.tun)),
    );
  }

  @override
  Future<bool> startVpn({required AccessControl accessControl}) => Future.error(
        UnsupportedError(desktopCapabilityMessage(DesktopCapability.tun)),
      );

  @override
  Future<void> stopVpn() => Future.error(
        UnsupportedError(desktopCapabilityMessage(DesktopCapability.tun)),
      );
}

/// A deliberately channel-free shell. Android-only lifecycle hooks are no-ops;
/// actual privileged work remains unavailable through [DesktopCapability].
class DesktopShellService implements ProductShellService {
  const DesktopShellService();

  @override
  void bindTileCommands({
    FutureOr<void> Function()? onStart,
    FutureOr<void> Function()? onStop,
    FutureOr<void> Function(String mode)? onChangeMode,
  }) {}

  @override
  String buildForegroundNotificationTitle({
    required Profile? profile,
    Iterable<Group> groups = const [],
  }) =>
      profile?.label ?? 'FlClashM';

  @override
  Future<void> initShortcuts() async {}

  @override
  void installExitHook(FutureOr<void> Function() onExit) {}

  @override
  Future<void> moveTaskToBack() async {}

  @override
  Future<void> notifyNoProfileSelected() async {}

  @override
  Future<void> notifyRuntimeNotReady() async {}

  @override
  Future<void> notifyStartError(Object error) async {}

  @override
  Future<void> notifyStartRequested() async {}

  @override
  Future<void> notifyStopRequested() async {}

  @override
  Future<void> notifyVpnStartFailed() async {}

  @override
  Future<void> pushForegroundNotificationTitle(String title) async {}

  @override
  Future<void> showTip(String message) async {}

  @override
  Future<void> signalServiceReady() async {}

  @override
  Future<void> syncForegroundNotification({
    required Profile? profile,
    Iterable<Group> groups = const [],
  }) async {}

  @override
  Future<void> syncForegroundNotificationForProxyChange({
    required Profile? profile,
    required String groupName,
    required String proxyName,
  }) async {}

  @override
  Future<void> syncGlobalModeEnabled({required bool enabled}) async {}

  @override
  Future<void> syncTileForProfileChange() async {}

  @override
  Future<void> syncTileMode(Mode mode) async {}

  @override
  Future<void> updateExcludeFromRecents({required bool hidden}) async {}
}
