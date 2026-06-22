import 'dart:async';
import 'dart:convert';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_shell_bridge.dart';
import 'package:flclashx/product/services/android_shell_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidShellService', () {
    test('syncs foreground notification title through the platform bridge',
        () async {
      final bridge = _FakeAndroidShellPlatformBridge();
      final service = AndroidShellService(platform: bridge);
      final profile = Profile(
        id: 'profile-1',
        label: 'Fallback Profile',
        autoUpdateDuration: Duration.zero,
        selectedMap: const {'Auto': 'Selected Proxy'},
        providerHeaders: {
          'flclashm-servicename': base64.encode(utf8.encode('Service Name')),
          'flclashm-serverinfo': base64.encode(utf8.encode('Auto')),
        },
      );

      await service.syncForegroundNotification(
        profile: profile,
        groups: const [
          Group(
            type: GroupType.Selector,
            name: 'Auto',
            now: 'Runtime Proxy',
          ),
        ],
      );

      expect(bridge.pushedTitles, ['Service Name / Runtime Proxy']);
    });

    test('syncs proxy-change titles only for the tracked server group',
        () async {
      final bridge = _FakeAndroidShellPlatformBridge();
      final service = AndroidShellService(platform: bridge);
      final profile = Profile(
        id: 'profile-2',
        label: 'Profile',
        autoUpdateDuration: Duration.zero,
        providerHeaders: {
          'flclashm-servicename': base64.encode(utf8.encode('Service Name')),
          'flclashm-serverinfo': base64.encode(utf8.encode('Auto')),
        },
      );

      await service.syncForegroundNotificationForProxyChange(
        profile: profile,
        groupName: 'Fallback',
        proxyName: 'Node B',
      );
      expect(bridge.pushedTitles, isEmpty);

      await service.syncForegroundNotificationForProxyChange(
        profile: profile,
        groupName: 'Auto',
        proxyName: 'Node B',
      );
      expect(bridge.pushedTitles, ['Service Name / Node B']);
    });

    test('delegates tile and app hooks through the platform bridge', () async {
      final bridge = _FakeAndroidShellPlatformBridge();
      final service = AndroidShellService(platform: bridge);
      var started = false;
      var stopped = false;
      var changedMode = '';
      var exitHookCalled = false;

      service
        ..bindTileCommands(
          onStart: () {
            started = true;
          },
          onStop: () {
            stopped = true;
          },
          onChangeMode: (mode) {
            changedMode = mode;
          },
        )
        ..installExitHook(() {
          exitHookCalled = true;
        });

      await bridge.triggerStart();
      await bridge.triggerStop();
      await bridge.triggerChangeMode('rule');
      await bridge.triggerExit();
      await service.signalServiceReady();
      await service.syncTileForProfileChange();
      await service.syncTileMode(Mode.direct);
      await service.syncGlobalModeEnabled(enabled: true);
      await service.moveTaskToBack();
      await service.updateExcludeFromRecents(hidden: true);
      await service.showTip('shell-tip');
      await service.pushForegroundNotificationTitle('Foreground Title');

      expect(started, isTrue);
      expect(stopped, isTrue);
      expect(changedMode, 'rule');
      expect(exitHookCalled, isTrue);
      expect(bridge.serviceReadySignals, 1);
      expect(bridge.tileSyncCount, 1);
      expect(bridge.syncedModes, ['direct']);
      expect(bridge.globalModeValues, [true]);
      expect(bridge.moveTaskToBackCount, 1);
      expect(bridge.excludeFromRecentsValues, [true]);
      expect(bridge.tips, ['shell-tip']);
      expect(bridge.pushedTitles, ['Foreground Title']);
    });
  });
}

class _FakeAndroidShellPlatformBridge implements AndroidShellPlatformBridge {
  AndroidTileStartHandler? _onStart;
  AndroidTileStopHandler? _onStop;
  AndroidTileModeHandler? _onChangeMode;
  FutureOr<void> Function()? _onExit;

  final pushedTitles = <String>[];
  final syncedModes = <String>[];
  final globalModeValues = <bool>[];
  final excludeFromRecentsValues = <bool>[];
  final tips = <String>[];
  int serviceReadySignals = 0;
  int tileSyncCount = 0;
  int moveTaskToBackCount = 0;

  @override
  void bindTileCommands({
    AndroidTileStartHandler? onStart,
    AndroidTileStopHandler? onStop,
    AndroidTileModeHandler? onChangeMode,
  }) {
    _onStart = onStart;
    _onStop = onStop;
    _onChangeMode = onChangeMode;
  }

  @override
  void setExitHandler(FutureOr<void> Function()? onExit) {
    _onExit = onExit;
  }

  @override
  Future<void> signalServiceReady() async {
    serviceReadySignals += 1;
  }

  @override
  Future<void> syncTile() async {
    tileSyncCount += 1;
  }

  @override
  Future<void> syncTileMode(String mode) async {
    syncedModes.add(mode);
  }

  @override
  Future<void> syncGlobalModeEnabled({required bool enabled}) async {
    globalModeValues.add(enabled);
  }

  @override
  Future<void> initShortcuts() async {}

  @override
  Future<void> moveTaskToBack() async {
    moveTaskToBackCount += 1;
  }

  @override
  Future<void> updateExcludeFromRecents({required bool hidden}) async {
    excludeFromRecentsValues.add(hidden);
  }

  @override
  Future<void> showTip(String message) async {
    tips.add(message);
  }

  @override
  Future<void> pushForegroundNotificationTitle(String title) async {
    pushedTitles.add(title);
  }

  Future<void> triggerStart() async {
    await _onStart?.call();
  }

  Future<void> triggerStop() async {
    await _onStop?.call();
  }

  Future<void> triggerChangeMode(String mode) async {
    await _onChangeMode?.call(mode);
  }

  Future<void> triggerExit() async {
    await _onExit?.call();
  }
}
