import 'dart:async';
import 'dart:io';

import 'package:flclashx/clash/lib.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/plugins/tile.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppStateManager extends ConsumerStatefulWidget {

  const AppStateManager({
    super.key,
    required this.child,
  });
  final Widget child;

  @override
  ConsumerState<AppStateManager> createState() => _AppStateManagerState();
}

class _AppStateManagerState extends ConsumerState<AppStateManager>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(layoutChangeProvider, (prev, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (prev != next) {
          globalState.cacheHeightMap = {};
        }
      });
    });
    ref.listenManual(
      checkIpProvider,
      (prev, next) {
        if (prev != next && next.b) {
          detectionState.startCheck();
        }
      },
      fireImmediately: true,
    );
    ref.listenManual(configStateProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.savePreferencesDebounce();
      }
    });
    ref.listenManual(
      autoSetSystemDnsStateProvider,
      (prev, next) async {
        if (prev == next) {
          return;
        }
        if (next.a == true && next.b == true) {
          system.setMacOSDns(false);
        } else {
          system.setMacOSDns(true);
        }
      },
    );
    ref.listenManual(
      patchClashConfigProvider.select((state) => state.mode),
      (prev, next) {
        if (prev != next) {
          tile?.updateMode(next.name);
        }
      },
      fireImmediately: true,
    );
    ref.listenManual(
      globalModeEnabledProvider,
      (prev, next) {
        if (prev != next) {
          tile?.updateGlobalModeEnabled(next);
        }
      },
      fireImmediately: true,
    );
    ref.listenManual(
      globalModeEnabledProvider,
      (prev, next) {
        if (next) {
          return;
        }
        final currentMode = ref.read(
          patchClashConfigProvider.select((state) => state.mode),
        );
        if (currentMode != Mode.global) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          globalState.appController.changeMode(Mode.rule);
        });
      },
      fireImmediately: true,
    );
  }

  @override
  void reassemble() {
    super.reassemble();
  }

  @override
  void dispose() async {
    await system.setMacOSDns(true);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    commonPrint.log("$state");
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      globalState.appController.savePreferences();
      if (Platform.isAndroid) {
        globalState.stopUpdateTasks();
        globalState.appController.stopRunTimeTimer();
      }
    } else {
      render?.resume();
      if (state == AppLifecycleState.resumed && Platform.isAndroid) {
        clashLib?.reconnectIfNeeded();
        if (globalState.isStart) {
          globalState.startUpdateTasks();
          globalState.appController.startRunTimeTimer();
        }
      }
    }
  }

  @override
  void didChangePlatformBrightness() {
    globalState.appController.updateBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

  @override
  Widget build(BuildContext context) => Listener(
      onPointerHover: (_) {
        render?.resume();
      },
      child: widget.child,
    );
}

class AppEnvManager extends StatelessWidget {

  const AppEnvManager({
    super.key,
    required this.child,
  });
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      if (globalState.isPre) {
        return Banner(
          message: 'DEBUG',
          location: BannerLocation.topEnd,
          child: child,
        );
      }
    }
    if (globalState.isPre) {
      return Banner(
        message: 'PRE',
        location: BannerLocation.topEnd,
        child: child,
      );
    }
    return child;
  }
}
