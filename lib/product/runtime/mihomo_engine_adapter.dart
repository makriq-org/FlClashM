import 'dart:async';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';

import '../compile/product_compile.dart';
import '../services/product_services.dart';
import 'built_in_proxy_supervisor.dart';
import 'built_in_proxy_types.dart';
import 'engine_adapter.dart';

typedef ReadAccessControlCallback = AccessControl Function();
typedef ReadProfileAccessControlCallback = AccessControl? Function();

abstract interface class MihomoCoreBridge {
  Future<void> shutdown();

  Future<bool> isInitialized();

  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  });

  Future<String> setupRuntimePlan(RuntimePlan runtimePlan);

  Future<String> updateRuntimeConfig(UpdateParams updateParams);

  Future<void> startListener();

  Future<void> stopListener();
}

class DefaultMihomoCoreBridge implements MihomoCoreBridge {
  const DefaultMihomoCoreBridge();

  @override
  Future<void> shutdown() => clashCore.shutdown();

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
  Future<void> startListener() => clashCore.startListener();

  @override
  Future<void> stopListener() => clashCore.stopListener();
}

abstract interface class MihomoLifecycleBridge {
  Future<void> restartRuntime();

  Future<DateTime?> readStartTime();

  Future<void> persistColdStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  });
}

class DefaultMihomoLifecycleBridge implements MihomoLifecycleBridge {
  const DefaultMihomoLifecycleBridge();

  @override
  Future<void> restartRuntime() async {
    if (clashService != null) {
      await clashService!.reStart();
      return;
    }
    clashLib?.reStart();
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

abstract interface class MihomoPlatformBridge {
  Future<void> pushForegroundNotificationTitle(String title);

  Future<bool> startVpn({required AccessControl accessControl});

  Future<void> stopVpn();
}

class DefaultMihomoPlatformBridge implements MihomoPlatformBridge {
  const DefaultMihomoPlatformBridge();

  @override
  Future<void> pushForegroundNotificationTitle(String title) =>
      productServices.androidShell.pushForegroundNotificationTitle(title);

  @override
  Future<bool> startVpn({required AccessControl accessControl}) =>
      productServices.accessControl.startVpn(accessControl: accessControl);

  @override
  Future<void> stopVpn() => productServices.accessControl.stopVpn();
}

class _BoundaryCleanupFailure {
  const _BoundaryCleanupFailure({
    required this.message,
    required this.stackTrace,
  });

  final String message;
  final StackTrace stackTrace;
}

class MihomoEngineAdapter implements EngineAdapter {
  MihomoEngineAdapter({
    this.core = const DefaultMihomoCoreBridge(),
    this.lifecycle = const DefaultMihomoLifecycleBridge(),
    this.platform = const DefaultMihomoPlatformBridge(),
    BuiltInProxySupervisor? builtInProxySupervisor,
    required ReadAccessControlCallback readAccessControl,
    ReadProfileAccessControlCallback? readProfileAccessControl,
  })  : _readAccessControl = readAccessControl,
        _readProfileAccessControl = readProfileAccessControl,
        builtInProxySupervisor =
            builtInProxySupervisor ?? DefaultBuiltInProxySupervisor();

  final MihomoCoreBridge core;
  final MihomoLifecycleBridge lifecycle;
  final MihomoPlatformBridge platform;
  final BuiltInProxySupervisor builtInProxySupervisor;
  final ReadAccessControlCallback _readAccessControl;
  final ReadProfileAccessControlCallback? _readProfileAccessControl;
  Future<void> _builtInProxyStartChain = Future.value();

  AccessControl get _accessControl => _readAccessControl();
  AccessControl? get _profileAccessControl => _readProfileAccessControl?.call();

  @override
  Future<void> prepareForRestart() async {
    if (await core.isInitialized()) {
      try {
        await core.shutdown();
      } catch (e) {
        commonPrint.log("Mihomo shutdown before restart failed: $e");
      }
    }

    try {
      await builtInProxySupervisor.prepareForRestart();
    } catch (e) {
      commonPrint.log("Built-in proxy restart prep failed: $e");
    }

    await lifecycle.restartRuntime();
  }

  @override
  Future<bool> isInitialized() => core.isInitialized();

  @override
  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  }) =>
      core.initialize(
        initParams: initParams,
        state: state,
      );

  @override
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) =>
      _setupRuntimePlan(runtimePlan);

  Future<String> _setupRuntimePlan(RuntimePlan runtimePlan) async {
    if (runtimePlan.builtInProxyNodes.isEmpty &&
        !builtInProxySupervisor.hasCommittedRuntimePlan) {
      return core.setupRuntimePlan(runtimePlan);
    }

    final stageMessage = await builtInProxySupervisor.stageRuntimePlan(
      runtimePlan.builtInProxyNodes,
    );
    if (stageMessage.isNotEmpty) {
      return stageMessage;
    }

    BuiltInProxyRuntimePlanStartResult? startedRuntimePlan;
    if (runtimePlan.builtInProxyNodes.isNotEmpty) {
      try {
        startedRuntimePlan = await builtInProxySupervisor.startRuntimePlan(
          runtimePlan.builtInProxyNodes,
          stopAllOnFailure: true,
        );
      } catch (e) {
        return _rollbackRuntimePlanSetup(
          message: 'Built-in proxy nodes failed to start: $e',
        );
      }

      if (!startedRuntimePlan.isSuccess) {
        return _rollbackRuntimePlanSetup(
          message: 'Built-in proxy nodes did not start.',
        );
      }
    }

    final message = await core.setupRuntimePlan(runtimePlan);
    if (message.isEmpty) {
      await builtInProxySupervisor.commitStagedRuntimePlan(
        runtimePlan.builtInProxyNodes,
      );
      return '';
    }

    return _rollbackRuntimePlanSetup(
      message: message,
      startedPlans: startedRuntimePlan?.startedPlans ?? const [],
    );
  }

  @override
  Future<String> updateRuntimeConfig(UpdateParams updateParams) =>
      core.updateRuntimeConfig(updateParams);

  @override
  Future<bool> start({String? notificationTitle}) async {
    if (notificationTitle != null && notificationTitle.isNotEmpty) {
      try {
        await platform.pushForegroundNotificationTitle(notificationTitle);
      } catch (e) {
        commonPrint.log("Failed to push mihomo notification title: $e");
      }
    }

    var listenerStarted = false;
    var vpnStartAttempted = false;

    try {
      await core.startListener();
      listenerStarted = true;

      if (await readStartTime() != null) {
        _startBuiltInProxyNodesInBackground();
        return true;
      }

      vpnStartAttempted = true;
      final started = await platform.startVpn(
        accessControl: productServices.accessControl.resolveVpnAccessControl(
          accessControl: _accessControl,
          profileAccessControl: _profileAccessControl,
        ),
      );
      if (started) {
        _startBuiltInProxyNodesInBackground();
        return true;
      }
    } catch (e, stackTrace) {
      final rollbackFailure = await _rollbackFailedStart(
        builtInNodesStarted: false,
        listenerStarted: listenerStarted,
        vpnStartAttempted: vpnStartAttempted,
      );
      if (rollbackFailure != null) {
        Error.throwWithStackTrace(
          StateError(
            'Mihomo start failed: $e. '
            'Cleanup also failed: ${rollbackFailure.message}',
          ),
          rollbackFailure.stackTrace,
        );
      }
      Error.throwWithStackTrace(e, stackTrace);
    }

    final rollbackFailure = await _rollbackFailedStart(
      builtInNodesStarted: false,
      listenerStarted: listenerStarted,
      vpnStartAttempted: vpnStartAttempted,
    );
    if (rollbackFailure != null) {
      Error.throwWithStackTrace(
        StateError(
          'Mihomo start returned false and cleanup failed: '
          '${rollbackFailure.message}',
        ),
        rollbackFailure.stackTrace,
      );
    }
    return false;
  }

  void _startBuiltInProxyNodesInBackground([
    List<BuiltInProxyNodePlan>? runtimePlan,
  ]) {
    final task = _builtInProxyStartChain.then((_) async {
      final message = await _startBuiltInProxyNodes(runtimePlan);
      if (message.isNotEmpty) {
        commonPrint.log(message);
      }
    });
    _builtInProxyStartChain = task.catchError((Object e, StackTrace s) {
      commonPrint.log('Failed to start built-in proxy nodes: $e');
    });
    unawaited(_builtInProxyStartChain);
  }

  Future<String> _startBuiltInProxyNodes([
    List<BuiltInProxyNodePlan>? runtimePlan,
  ]) async {
    try {
      final started = runtimePlan == null
          ? await builtInProxySupervisor.start(stopAllOnFailure: false)
          : (await builtInProxySupervisor.startRuntimePlan(
              runtimePlan,
              stopAllOnFailure: false,
            ))
              .isSuccess;
      if (started) {
        return '';
      }
      return 'Built-in proxy nodes did not start.';
    } catch (e) {
      return 'Failed to start built-in proxy nodes: $e';
    }
  }

  Future<String> _rollbackRuntimePlanSetup({
    required String message,
    List<BuiltInProxyNodePlan> startedPlans = const [],
  }) async {
    final cleanupMessages = <String>[];

    if (startedPlans.isNotEmpty) {
      try {
        await builtInProxySupervisor.stopRuntimePlan(startedPlans);
      } catch (e) {
        cleanupMessages.add('Failed to stop started local nodes: $e');
      }
    }

    final rollbackMessage =
        await builtInProxySupervisor.rollbackStagedRuntimePlan();
    if (rollbackMessage.isNotEmpty) {
      cleanupMessages.add(rollbackMessage);
    }

    if (cleanupMessages.isEmpty) {
      return message;
    }
    return '$message Local-node rollback failed: ${cleanupMessages.join(' ')}';
  }

  @override
  Future<void> stop() async {
    Object? error;
    StackTrace? stackTrace;

    try {
      await core.stopListener();
    } catch (e, s) {
      error ??= e;
      stackTrace ??= s;
    }

    try {
      await platform.stopVpn();
    } catch (e, s) {
      if (error != null) {
        commonPrint.log("Failed to stop VPN after listener stop error: $e");
      } else {
        error = e;
        stackTrace = s;
      }
    }

    try {
      await builtInProxySupervisor.stop();
    } catch (e, s) {
      if (error != null) {
        commonPrint
            .log("Failed to stop built-in proxy nodes after stop error: $e");
      } else {
        error = e;
        stackTrace = s;
      }
    }

    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  @override
  Future<DateTime?> readStartTime() => lifecycle.readStartTime();

  @override
  Future<void> persistColdStart({
    required InitParams initParams,
    required RuntimePlan runtimePlan,
    required CoreState state,
  }) async {
    await lifecycle.persistColdStart(
      initParams: initParams,
      setupParams: runtimePlan.toSetupParams(),
      state: state,
    );
    await builtInProxySupervisor.persistColdStart();
  }

  Future<_BoundaryCleanupFailure?> _rollbackFailedStart({
    required bool builtInNodesStarted,
    required bool listenerStarted,
    required bool vpnStartAttempted,
  }) async {
    _BoundaryCleanupFailure? failure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log("$message: $error");
      failure ??= _BoundaryCleanupFailure(
        message: '$message: $error',
        stackTrace: stackTrace,
      );
    }

    if (vpnStartAttempted) {
      try {
        await platform.stopVpn();
      } catch (e, s) {
        captureFailure('Failed to stop VPN during mihomo rollback', e, s);
      }
    }

    if (listenerStarted) {
      try {
        await core.stopListener();
      } catch (e, s) {
        captureFailure('Failed to stop listener during mihomo rollback', e, s);
      }
    }

    if (builtInNodesStarted) {
      try {
        await builtInProxySupervisor.stop();
      } catch (e, s) {
        captureFailure(
          'Failed to stop built-in proxy nodes during mihomo rollback',
          e,
          s,
        );
      }
    }

    return failure;
  }
}
