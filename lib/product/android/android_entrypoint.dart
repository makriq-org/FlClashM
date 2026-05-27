import 'dart:async';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/plugins/app.dart';
import 'package:flclashx/plugins/tile.dart';
import 'package:flclashx/state.dart';

import '../../common/common.dart';
import '../../models/models.dart';
import 'android_platform.dart';

class AndroidEntrypoint {
  AndroidEntrypoint._();

  static final AndroidEntrypoint instance = AndroidEntrypoint._();

  Future<void> init() async {
    tile?.addListener(_MainTileListener(this));
    // Let the Kotlin side replay pending START/STOP/CHANGE intents after the
    // Flutter engine is ready.
    unawaited(tile?.signalServiceReady());
  }

  Future<void> handleStart() async {
    try {
      unawaited(app?.tip(appLocalizations.startVpn));

      final profileId = globalState.config.currentProfileId;
      if (profileId == null) {
        unawaited(app?.tip("No profile selected"));
        return;
      }

      final isReady = await globalState.engineManager.waitUntilInitialized(
        attempts: 30,
        delay: const Duration(milliseconds: 500),
      );
      if (!isReady) {
        commonPrint.log("Tile start: runtime is not ready");
        unawaited(app?.tip("Runtime is not ready"));
        return;
      }

      final profile = globalState.config.currentProfile;
      final title = androidPlatform.foregroundNotification.buildTitle(profile);
      final started = await globalState.engineManager.start(
        updateTasks: globalState.isInit
            ? [globalState.appController.updateTraffic]
            : null,
        notificationTitle: title,
      );
      if (!started) {
        commonPrint.log("Tile start: runtime start failed");
        unawaited(app?.tip("VPN start failed"));
        return;
      }

      if (globalState.isInit) {
        await globalState.appController.onRuntimeStarted(
          checkProfileModified: false,
        );
      }
    } catch (e, stackTrace) {
      commonPrint.log("Tile onStart error: $e\n$stackTrace");
      unawaited(app?.tip("Start error: $e"));
    }
  }

  Future<void> handleStop() async {
    try {
      unawaited(app?.tip(appLocalizations.stopVpn));
      await globalState.engineManager.stop();
      if (globalState.isInit) {
        await globalState.appController.onRuntimeStopped();
      }
    } catch (e) {
      commonPrint.log("Tile onStop error: $e");
    }
  }

  Future<void> handleChangeMode(String mode) async {
    try {
      final modeEnum = Mode.values.byName(mode);
      final patched = globalState.config.patchClashConfig.copyWith(
        mode: modeEnum,
      );
      if (globalState.isInit) {
        globalState.appController.syncPatchClashConfigFromRuntime(patched);
      } else {
        globalState.config = globalState.config.copyWith(
          patchClashConfig: patched,
        );
      }
      await preferences.saveConfig(globalState.config);

      final updated = await globalState.engineManager.updateConfig(
        UpdateParams(
          tun:
              patched.tun.getRealTun(globalState.config.networkProps.routeMode),
          allowLan: patched.allowLan,
          findProcessMode: patched.findProcessMode,
          mode: modeEnum,
          logLevel: patched.logLevel,
          ipv6: patched.ipv6,
          tcpConcurrent: patched.tcpConcurrent,
          externalController: patched.externalController,
          unifiedDelay: patched.unifiedDelay,
          mixedPort: patched.mixedPort,
        ),
        coldStartPatchConfig: patched.copyWith.tun(enable: false),
      );
      if (!updated) {
        return;
      }
      unawaited(tile?.updateMode(mode));
    } catch (e) {
      commonPrint.log("Tile onChangeMode error: $e");
    }
  }
}

class _MainTileListener with TileListener {
  _MainTileListener(this.entrypoint);

  final AndroidEntrypoint entrypoint;

  @override
  void onStart() {
    unawaited(entrypoint.handleStart());
  }

  @override
  void onStop() {
    unawaited(entrypoint.handleStop());
  }

  @override
  void onChangeMode(String mode) {
    unawaited(entrypoint.handleChangeMode(mode));
  }
}

final androidEntrypoint = AndroidEntrypoint.instance;
