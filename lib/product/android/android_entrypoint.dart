import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/models/models.dart';
import 'package:flclashm/product/services/product_services.dart';
import 'package:flclashm/state.dart';

import '../../common/common.dart';

class AndroidEntrypoint {
  AndroidEntrypoint._();

  static final AndroidEntrypoint instance = AndroidEntrypoint._();

  Future<void> init() async {
    productServices.androidShell.bindTileCommands(
      onStart: handleStart,
      onStop: handleStop,
      onChangeMode: handleChangeMode,
    );
    await productServices.androidShell.signalServiceReady();
  }

  Future<void> handleStart() async {
    try {
      await productServices.androidShell.notifyStartRequested();

      final profileId = globalState.config.currentProfileId;
      if (profileId == null) {
        await productServices.androidShell.notifyNoProfileSelected();
        return;
      }

      final isReady = await globalState.engineManager.waitUntilInitialized(
        attempts: 30,
        delay: const Duration(milliseconds: 500),
      );
      if (!isReady) {
        commonPrint.log("Tile start: runtime is not ready");
        await productServices.androidShell.notifyRuntimeNotReady();
        return;
      }

      final profile = globalState.config.currentProfile;
      final title =
          productServices.androidShell.buildForegroundNotificationTitle(
        profile: profile,
      );
      final started = await globalState.engineManager.start(
        updateTasks: globalState.isInit
            ? [globalState.appController.updateTraffic]
            : null,
        notificationTitle: title,
      );
      if (!started) {
        commonPrint.log("Tile start: runtime start failed");
        await productServices.androidShell.notifyVpnStartFailed();
        return;
      }

      if (globalState.isInit) {
        await globalState.appController.onRuntimeStarted(
          checkProfileModified: false,
        );
      }
    } catch (e, stackTrace) {
      commonPrint.log("Tile onStart error: $e\n$stackTrace");
      await productServices.androidShell.notifyStartError(e);
    }
  }

  Future<void> handleStop() async {
    try {
      await productServices.androidShell.notifyStopRequested();
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
      final requestedPatchConfig = globalState.config.patchClashConfig.copyWith(
        mode: modeEnum,
      );
      final patched = globalState.securePatchConfig(
        patchConfig: requestedPatchConfig,
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
        globalState.buildRuntimeUpdateParams(
          patchConfig: patched,
        ),
        coldStartPatchConfig: patched.copyWith.tun(enable: false),
      );
      if (!updated) {
        return;
      }
      await productServices.androidShell.syncTileMode(modeEnum);
    } catch (e) {
      commonPrint.log("Tile onChangeMode error: $e");
    }
  }
}

final androidEntrypoint = AndroidEntrypoint.instance;
