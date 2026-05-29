import 'dart:io';

import 'package:flclashm/clash/clash.dart';
import 'package:flclashm/common/common.dart';
import 'package:flclashm/models/models.dart';

import '../compile/product_compile.dart';
import '../services/product_services.dart';
import 'built_in_proxy_supervisor.dart';
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

abstract interface class MihomoUpdateBridge {
  String get corePath;

  String get corePendingPath;

  bool get supportsExecutableBit;

  Future<void> setExecutable(String path);
}

class DefaultMihomoUpdateBridge implements MihomoUpdateBridge {
  const DefaultMihomoUpdateBridge();

  @override
  String get corePath => appPath.corePath;

  @override
  String get corePendingPath => appPath.corePendingPath;

  @override
  bool get supportsExecutableBit => !Platform.isWindows;

  @override
  Future<void> setExecutable(String path) async {
    if (!supportsExecutableBit) {
      return;
    }

    final result = await Process.run('chmod', ['+x', path]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'chmod',
        ['+x', path],
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }
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
    this.update = const DefaultMihomoUpdateBridge(),
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
  final MihomoUpdateBridge update;
  final BuiltInProxySupervisor builtInProxySupervisor;
  final ReadAccessControlCallback _readAccessControl;
  final ReadProfileAccessControlCallback? _readProfileAccessControl;

  AccessControl get _accessControl => _readAccessControl();
  AccessControl? get _profileAccessControl => _readProfileAccessControl?.call();

  String get _coreRollbackPath => '${update.corePath}.rollback';

  @override
  Future<void> applyPendingUpdate() async {
    await builtInProxySupervisor.applyPendingUpdate();
    final pending = File(update.corePendingPath);
    if (!pending.existsSync()) {
      return;
    }

    commonPrint.log("Applying pending core update...");
    final target = File(update.corePath);
    final rollback = File(_coreRollbackPath);
    var targetMovedToRollback = false;
    var pendingMovedToTarget = false;

    try {
      await _deleteWithRetry(rollback);
      if (target.existsSync()) {
        await _renameWithRetry(target, rollback.path);
        targetMovedToRollback = true;
      }

      await _renameWithRetry(pending, target.path);
      pendingMovedToTarget = true;
      await update.setExecutable(target.path);
      await _deleteWithRetry(rollback);
      commonPrint.log("Pending core update applied successfully");
    } catch (e, stackTrace) {
      final rollbackFailure = await _rollbackPendingUpdate(
        target: target,
        pending: pending,
        rollback: rollback,
        targetMovedToRollback: targetMovedToRollback,
        pendingMovedToTarget: pendingMovedToTarget,
      );
      commonPrint.log("Failed to apply pending core update: $e");
      if (rollbackFailure != null) {
        Error.throwWithStackTrace(
          StateError(
            'Failed to apply pending core update: $e. '
            'Rollback also failed: ${rollbackFailure.message}',
          ),
          rollbackFailure.stackTrace,
        );
      }
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

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
    final stageMessage = await builtInProxySupervisor.stageRuntimePlan(
      runtimePlan.builtInProxyNodes,
    );
    if (stageMessage.isNotEmpty) {
      return stageMessage;
    }

    final message = await core.setupRuntimePlan(runtimePlan);
    if (message.isEmpty) {
      await builtInProxySupervisor.commitStagedRuntimePlan(
        runtimePlan.builtInProxyNodes,
      );
      return '';
    }

    final rollbackMessage =
        await builtInProxySupervisor.rollbackStagedRuntimePlan();
    if (rollbackMessage.isEmpty) {
      return message;
    }
    return '$message Local-node rollback failed: $rollbackMessage';
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

    var builtInNodesStarted = false;
    var listenerStarted = false;
    var vpnStartAttempted = false;

    try {
      builtInNodesStarted = await builtInProxySupervisor.start();
      if (!builtInNodesStarted) {
        return false;
      }

      await core.startListener();
      listenerStarted = true;

      if (await readStartTime() != null) {
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
        return true;
      }
    } catch (e, stackTrace) {
      final rollbackFailure = await _rollbackFailedStart(
        builtInNodesStarted: builtInNodesStarted,
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
      builtInNodesStarted: builtInNodesStarted,
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

  Future<_BoundaryCleanupFailure?> _rollbackPendingUpdate({
    required File target,
    required File pending,
    required File rollback,
    required bool targetMovedToRollback,
    required bool pendingMovedToTarget,
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

    try {
      if (pendingMovedToTarget &&
          target.existsSync() &&
          !pending.existsSync()) {
        await _renameWithRetry(target, pending.path);
      }
    } catch (e, s) {
      captureFailure('Failed to move new core back to pending', e, s);
    }

    if (targetMovedToRollback) {
      try {
        if (rollback.existsSync()) {
          await _deleteWithRetry(target);
          await _renameWithRetry(rollback, target.path);
        }
      } catch (e, s) {
        captureFailure(
            'Failed to restore previous core after update error', e, s);
      } finally {
        try {
          await _deleteWithRetry(rollback);
        } catch (e, s) {
          captureFailure(
              'Failed to clean rollback core after update error', e, s);
        }
      }
    }

    return failure;
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

  Future<void> _deleteWithRetry(File file) async {
    if (!file.existsSync()) {
      return;
    }

    for (var i = 0; i < 10; i++) {
      try {
        await file.delete();
        return;
      } catch (_) {
        if (i == 9) {
          rethrow;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _renameWithRetry(File source, String targetPath) async {
    for (var i = 0; i < 10; i++) {
      try {
        await source.rename(targetPath);
        return;
      } catch (_) {
        if (i == 9) {
          rethrow;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }
}
