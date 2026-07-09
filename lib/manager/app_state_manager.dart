import 'dart:async';
import 'dart:io';

import 'package:flclashx/clash/core.dart';
import 'package:flclashx/clash/lib.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/product/services/product_services.dart';
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
    } else if (state == AppLifecycleState.hidden) {
      // Desktop window hidden (tray/minimize). Falling through to the generic
      // resume branch cancelled the throttled render pause armed by
      // window.hide(), so the engine kept rasterizing dashboard animations in
      // an invisible window.
      render?.pause();
    } else {
      render?.resume();
      if (state == AppLifecycleState.resumed && Platform.isAndroid) {
        // Re-assert the per-session core wiring against the (possibly recycled)
        // :remote core. A warm app-open after a headless tile start keeps this
        // engine's one-time event-pipe registration + log/request producers, but the
        // :remote core has been replaced — so logs/journal/delays silently stop
        // arriving (only the polled traffic survives). All idempotent and mirror what
        // the cold-start path already does.
        clashLib?.reconnectIfNeeded();
        clashCore.setUiActive(true);
        // Re-subscribe the log stream: the log subscriber lives in :remote and is gone
        // after a recycle, and nothing else re-issues it on resume. Gated on openLogs.
        if (globalState.config.appSetting.openLogs) {
          clashCore.startLog();
        } else {
          clashCore.stopLog();
        }
        globalState.startGroupsUpdateTask();
        globalState.appController.updateGroupsDebounce();
        // Optimistically restart timers from the cached state so the runtime
        // display doesn't stall while the probe below is in flight...
        if (globalState.isStart) {
          await globalState.engineManager.resumeUpdateTasks();
          globalState.appController.startRunTimeTimer();
        }
        // ...then align with the native truth: STOP/START events are lost
        // while the process is frozen/killed, and the cached state never
        // self-heals without this.
        unawaited(globalState.appController.syncVpnStateOnResume());
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
