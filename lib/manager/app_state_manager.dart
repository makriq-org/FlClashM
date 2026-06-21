import 'dart:async';
import 'dart:io';

import 'package:flclashm/clash/core.dart';
import 'package:flclashm/clash/lib.dart';
import 'package:flclashm/common/common.dart';
import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/product/services/product_services.dart';
import 'package:flclashm/providers/providers.dart';
import 'package:flclashm/state.dart';
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
  // Serializes macOS system-DNS set/restore so concurrent listener fires (rapid
  // toggle / TUN flap) can't interleave networksetup calls and snapshot a transient
  // injected value as the "origin".
  Future<void> _dnsOp = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      // Assert foreground cadence as soon as the UI mounts. A headless cold-start
      // leaves the core in background mode (uiActive=false, set by FlVpnService),
      // and the initial 'resumed' is a state — not always a lifecycle *event* — on a
      // fresh launch, so relying on didChangeAppLifecycleState alone could strand the
      // UI in background cadence (no request forwarder, slow pings).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        clashCore.setUiActive(true);
      });
    }
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
      (prev, next) {
        if (prev == next) {
          return;
        }
        final restore = !(next.a == true && next.b == true);
        // Chain through _dnsOp so set/restore never overlap; catchError keeps the
        // chain alive if one networksetup invocation throws.
        _dnsOp = _dnsOp
            .then((_) => system.setMacOSDns(restore))
            .catchError((_) {});
      },
    );
    ref.listenManual(
      patchClashConfigProvider.select((state) => state.mode),
      (prev, next) {
        if (prev != next) {
          unawaited(productServices.androidShell.syncTileMode(next));
        }
      },
      fireImmediately: true,
    );
    ref.listenManual(
      globalModeEnabledProvider,
      (prev, next) {
        if (prev != next) {
          unawaited(
            productServices.androidShell.syncGlobalModeEnabled(enabled: next),
          );
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
  void dispose() {
    // The real teardown DNS restore runs in controller.handleExit (bounded + awaited
    // before shutdown); dispose() is not awaited by the framework, so doing async
    // work here was unreliable and delayed observer teardown.
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
        globalState.engineManager.pauseUpdateTasks();
        globalState.appController.stopRunTimeTimer();
        globalState.stopGroupsUpdateTask();
        // Tell the core the UI is backgrounded: it pauses the request forwarder
        // and stretches the health-check forwarder to a slow interval so it stops
        // pinging every proxy every few seconds for a UI nobody is looking at.
        clashCore.setUiActive(false);
      }
    } else {
      render?.resume();
      if (state == AppLifecycleState.resumed && Platform.isAndroid) {
        clashLib?.reconnectIfNeeded();
        clashCore.setUiActive(true);
        globalState.startGroupsUpdateTask();
        globalState.appController.updateGroupsDebounce();
        if (globalState.isStart) {
          await globalState.engineManager.resumeUpdateTasks();
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
