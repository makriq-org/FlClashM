import 'dart:async';

import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../android/android_foreground_notification_policy.dart';
import '../android/android_shell_bridge.dart';

class AndroidShellService {
  AndroidShellService({
    this.platform = const AndroidShellBridge(),
    this.foregroundNotification = const AndroidForegroundNotificationPolicy(),
  });

  final AndroidShellPlatformBridge platform;
  final AndroidForegroundNotificationPolicy foregroundNotification;
  Future<void> _notificationPushChain = Future<void>.value();
  String? _lastForegroundNotificationTitle;

  void bindTileCommands({
    AndroidTileStartHandler? onStart,
    AndroidTileStopHandler? onStop,
    AndroidTileModeHandler? onChangeMode,
  }) {
    platform.bindTileCommands(
      onStart: onStart,
      onStop: onStop,
      onChangeMode: onChangeMode,
    );
  }

  void installExitHook(FutureOr<void> Function() onExit) {
    platform.setExitHandler(onExit);
  }

  Future<void> signalServiceReady() => platform.signalServiceReady();

  Future<void> initShortcuts() => platform.initShortcuts();

  Future<void> moveTaskToBack() => platform.moveTaskToBack();

  Future<void> updateExcludeFromRecents({required bool hidden}) =>
      platform.updateExcludeFromRecents(hidden: hidden);

  Future<void> syncTileForProfileChange() => platform.syncTile();

  Future<void> syncTileMode(Mode mode) => platform.syncTileMode(mode.name);

  Future<void> syncGlobalModeEnabled({required bool enabled}) =>
      platform.syncGlobalModeEnabled(enabled: enabled);

  Future<void> notifyStartRequested() => showTip(appLocalizations.startVpn);

  Future<void> notifyStopRequested() => showTip(appLocalizations.stopVpn);

  Future<void> notifyNoProfileSelected() => showTip('No profile selected');

  Future<void> notifyRuntimeNotReady() => showTip('Runtime is not ready');

  Future<void> notifyVpnStartFailed() => showTip('VPN start failed');

  Future<void> notifyStartError(Object error) => showTip('Start error: $error');

  Future<void> showTip(String message) => platform.showTip(message);

  String buildForegroundNotificationTitle({
    required Profile? profile,
    Iterable<Group> groups = const [],
  }) =>
      foregroundNotification.buildTitle(profile, groups: groups);

  Future<void> pushForegroundNotificationTitle(String title) {
    if (title.isEmpty) {
      return Future<void>.value();
    }
    final push = _notificationPushChain.then((_) async {
      if (_lastForegroundNotificationTitle == title) {
        return;
      }
      await platform.pushForegroundNotificationTitle(title);
      _lastForegroundNotificationTitle = title;
    });
    _notificationPushChain = push.catchError((_) {});
    return push;
  }

  Future<void> syncForegroundNotification({
    required Profile? profile,
    Iterable<Group> groups = const [],
  }) async {
    await pushForegroundNotificationTitle(
      buildForegroundNotificationTitle(
        profile: profile,
        groups: groups,
      ),
    );
  }

  Future<void> syncForegroundNotificationForProxyChange({
    required Profile? profile,
    required String groupName,
    required String proxyName,
  }) async {
    final title = foregroundNotification.buildTitleForProxyChange(
      profile,
      groupName: groupName,
      proxyName: proxyName,
    );
    if (title == null || title.isEmpty) {
      return;
    }
    await pushForegroundNotificationTitle(title);
  }
}
