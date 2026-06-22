import 'dart:async';

import '../../clash/clash.dart';
import '../../plugins/app.dart';
import '../../plugins/tile.dart';

typedef AndroidTileStartHandler = FutureOr<void> Function();
typedef AndroidTileStopHandler = FutureOr<void> Function();
typedef AndroidTileModeHandler = FutureOr<void> Function(String mode);

abstract interface class AndroidShellPlatformBridge {
  const AndroidShellPlatformBridge();

  void bindTileCommands({
    AndroidTileStartHandler? onStart,
    AndroidTileStopHandler? onStop,
    AndroidTileModeHandler? onChangeMode,
  });

  void setExitHandler(FutureOr<void> Function()? onExit);

  Future<void> signalServiceReady();

  Future<void> syncTile();

  Future<void> syncTileMode(String mode);

  Future<void> syncGlobalModeEnabled({required bool enabled});

  Future<void> initShortcuts();

  Future<void> moveTaskToBack();

  Future<void> updateExcludeFromRecents({required bool hidden});

  Future<void> showTip(String message);

  Future<void> pushForegroundNotificationTitle(String title);
}

class AndroidShellBridge implements AndroidShellPlatformBridge {
  const AndroidShellBridge();

  static final _tileListener = _AndroidShellTileListener();

  @override
  void bindTileCommands({
    AndroidTileStartHandler? onStart,
    AndroidTileStopHandler? onStop,
    AndroidTileModeHandler? onChangeMode,
  }) {
    tile?.removeListener(_tileListener);
    _tileListener
      ..startHandler = onStart
      ..stopHandler = onStop
      ..changeModeHandler = onChangeMode;
    if (onStart != null || onStop != null || onChangeMode != null) {
      tile?.addListener(_tileListener);
    }
  }

  @override
  void setExitHandler(FutureOr<void> Function()? onExit) {
    if (app == null) {
      return;
    }
    app!.onExit = onExit == null
        ? null
        : () async {
            await onExit();
          };
  }

  @override
  Future<void> signalServiceReady() async {
    await tile?.signalServiceReady();
  }

  @override
  Future<void> syncTile() async {
    await tile?.updateTile();
  }

  @override
  Future<void> syncTileMode(String mode) async {
    await tile?.updateMode(mode);
  }

  @override
  Future<void> syncGlobalModeEnabled({required bool enabled}) async {
    await tile?.updateGlobalModeEnabled(enabled);
  }

  @override
  Future<void> initShortcuts() async {
    await app?.initShortcuts();
  }

  @override
  Future<void> moveTaskToBack() async {
    await app?.moveTaskToBack();
  }

  @override
  Future<void> updateExcludeFromRecents({required bool hidden}) async {
    await app?.updateExcludeFromRecents(hidden);
  }

  @override
  Future<void> showTip(String message) async {
    if (message.isEmpty) {
      return;
    }
    await app?.tip(message);
  }

  @override
  Future<void> pushForegroundNotificationTitle(String title) async {
    if (title.isEmpty) {
      return;
    }
    await clashLib?.updateNotificationParams(title: title);
  }
}

class _AndroidShellTileListener with TileListener {
  AndroidTileStartHandler? startHandler;
  AndroidTileStopHandler? stopHandler;
  AndroidTileModeHandler? changeModeHandler;

  @override
  void onStart() {
    final handler = startHandler;
    if (handler != null) {
      final result = handler();
      if (result is Future<void>) {
        unawaited(result);
      }
    }
  }

  @override
  void onStop() {
    final handler = stopHandler;
    if (handler != null) {
      final result = handler();
      if (result is Future<void>) {
        unawaited(result);
      }
    }
  }

  @override
  void onChangeMode(String mode) {
    final handler = changeModeHandler;
    if (handler != null) {
      final result = handler(mode);
      if (result is Future<void>) {
        unawaited(result);
      }
    }
  }
}
