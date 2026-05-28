import 'dart:io';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/product_android.dart';
import 'package:flclashx/state.dart';

import '../compile/product_compile.dart';
import '../services/product_services.dart';
import 'engine_adapter.dart';

class MihomoEngineAdapter implements EngineAdapter {
  const MihomoEngineAdapter();

  @override
  Future<void> applyPendingUpdate() async {
    final pending = File(appPath.corePendingPath);
    if (!pending.existsSync()) {
      return;
    }

    commonPrint.log("Applying pending core update...");
    try {
      final target = File(appPath.corePath);
      if (target.existsSync()) {
        for (var i = 0; i < 10; i++) {
          try {
            await target.delete();
            break;
          } catch (_) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }

      await pending.rename(appPath.corePath);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', appPath.corePath]);
      }
      commonPrint.log("Pending core update applied successfully");
    } catch (e) {
      commonPrint.log("Failed to apply pending core update: $e");
    }
  }

  @override
  Future<void> prepareForRestart() async {
    if (await clashCore.isInit) {
      await clashCore.shutdown();
    }
    if (clashService != null) {
      await clashService?.reStart();
      return;
    }
    clashLib?.reStart();
  }

  @override
  Future<bool> isInitialized() async => await clashCore.isInit;

  @override
  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  }) async {
    await clashCore.init();
    await clashCore.setState(state);
  }

  @override
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) =>
      clashCore.setupConfig(runtimePlan.toSetupParams());

  @override
  Future<String> updateRuntimeConfig(UpdateParams updateParams) =>
      clashCore.updateConfig(updateParams);

  @override
  Future<bool> start({String? notificationTitle}) async {
    if (notificationTitle != null && notificationTitle.isNotEmpty) {
      await androidPlatform.foregroundNotification.pushTitle(notificationTitle);
    }

    await clashCore.startListener();
    if (await readStartTime() != null) {
      return true;
    }

    final started = await productServices.accessControl.startVpn(
      accessControl: globalState.config.vpnProps.accessControl,
    );
    if (!started) {
      await clashCore.stopListener();
    }
    return started;
  }

  @override
  Future<void> stop() async {
    await clashCore.stopListener();
    await productServices.accessControl.stopVpn();
  }

  @override
  Future<DateTime?> readStartTime() async => await clashLib?.getRunTime();

  @override
  Future<void> persistColdStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  }) async {
    await clashLib?.saveParamsForColdStart(
      initParams: initParams,
      setupParams: setupParams,
      state: state,
    );
  }
}
