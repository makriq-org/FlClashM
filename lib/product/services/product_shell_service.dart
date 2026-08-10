import 'dart:async';

import '../../enum/enum.dart';
import '../../models/models.dart';

/// Product-facing shell contract. Android owns the platform integrations;
/// desktop implementations deliberately do not bridge to Android channels.
abstract interface class ProductShellService {
  void bindTileCommands({
    FutureOr<void> Function()? onStart,
    FutureOr<void> Function()? onStop,
    FutureOr<void> Function(String mode)? onChangeMode,
  });

  void installExitHook(FutureOr<void> Function() onExit);

  Future<void> signalServiceReady();
  Future<void> initShortcuts();
  Future<void> moveTaskToBack();
  Future<void> updateExcludeFromRecents({required bool hidden});
  Future<void> syncTileForProfileChange();
  Future<void> syncTileMode(Mode mode);
  Future<void> syncGlobalModeEnabled({required bool enabled});
  Future<void> showTip(String message);
  Future<void> pushForegroundNotificationTitle(String title);

  String buildForegroundNotificationTitle({
    required Profile? profile,
    Iterable<Group> groups,
  });

  Future<void> syncForegroundNotification({
    required Profile? profile,
    Iterable<Group> groups,
  });

  Future<void> syncForegroundNotificationForProxyChange({
    required Profile? profile,
    required String groupName,
    required String proxyName,
  });

  Future<void> notifyStartRequested();
  Future<void> notifyStopRequested();
  Future<void> notifyNoProfileSelected();
  Future<void> notifyRuntimeNotReady();
  Future<void> notifyVpnStartFailed();
  Future<void> notifyStartError(Object error);
}
