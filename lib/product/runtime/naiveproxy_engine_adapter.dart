import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../android/android_naiveproxy_runtime_bridge.dart';
import '../compile/product_compile.dart';
import '../services/product_services.dart';
import 'engine_adapter.dart';
import 'naiveproxy_release.dart';

typedef ReadNaiveProxyAccessControlCallback = AccessControl Function();
typedef ReadNaiveProxyProfileAccessControlCallback = AccessControl? Function();
typedef WaitForNaiveProxyListenerCallback = Future<void> Function(
  String configPath,
);

abstract interface class NaiveProxyCoreBridge {
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

class DefaultNaiveProxyCoreBridge implements NaiveProxyCoreBridge {
  const DefaultNaiveProxyCoreBridge();

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

abstract interface class NaiveProxyLifecycleBridge {
  Future<void> restartRuntime();

  Future<DateTime?> readBridgeStartTime();

  Future<void> clearColdStartState();
}

class DefaultNaiveProxyLifecycleBridge implements NaiveProxyLifecycleBridge {
  const DefaultNaiveProxyLifecycleBridge({
    this.runtime = const AndroidNaiveProxyRuntimeBridge(),
  });

  final NaiveProxyRuntimePlatformBridge runtime;

  @override
  Future<void> restartRuntime() async {
    if (clashService != null) {
      await clashService!.reStart();
      return;
    }
    clashLib?.reStart();
  }

  @override
  Future<DateTime?> readBridgeStartTime() async => await clashLib?.getRunTime();

  @override
  Future<void> clearColdStartState() => runtime.clearColdStartState();
}

abstract interface class NaiveProxyPlatformBridge {
  Future<void> pushForegroundNotificationTitle(String title);

  Future<bool> startVpn({required AccessControl accessControl});

  Future<void> stopVpn();
}

class DefaultNaiveProxyPlatformBridge implements NaiveProxyPlatformBridge {
  const DefaultNaiveProxyPlatformBridge();

  @override
  Future<void> pushForegroundNotificationTitle(String title) =>
      productServices.androidShell.pushForegroundNotificationTitle(title);

  @override
  Future<bool> startVpn({required AccessControl accessControl}) =>
      productServices.accessControl.startVpn(accessControl: accessControl);

  @override
  Future<void> stopVpn() => productServices.accessControl.stopVpn();
}

abstract interface class NaiveProxyProcessBridge {
  Future<bool> startProcess({
    required String executablePath,
    required String workingDirectory,
  });

  Future<void> stopProcess();

  Future<DateTime?> readProcessStartTime();
}

class DefaultNaiveProxyProcessBridge implements NaiveProxyProcessBridge {
  const DefaultNaiveProxyProcessBridge({
    this.runtime = const AndroidNaiveProxyRuntimeBridge(),
  });

  final NaiveProxyRuntimePlatformBridge runtime;

  @override
  Future<bool> startProcess({
    required String executablePath,
    required String workingDirectory,
  }) =>
      runtime.startProcess(
        executablePath: executablePath,
        workingDirectory: workingDirectory,
      );

  @override
  Future<void> stopProcess() => runtime.stopProcess();

  @override
  Future<DateTime?> readProcessStartTime() => runtime.readProcessStartTime();
}

@immutable
class NaiveProxyInstallLayout {
  const NaiveProxyInstallLayout({
    required this.abi,
    required this.runtimeDirectoryPath,
    required this.executablePath,
    required this.pendingPath,
    required this.rollbackPath,
    required this.configPath,
    required this.versionPath,
    required this.pendingVersionPath,
    required this.bundledAssetPath,
  });

  final String abi;
  final String runtimeDirectoryPath;
  final String executablePath;
  final String pendingPath;
  final String rollbackPath;
  final String configPath;
  final String versionPath;
  final String pendingVersionPath;
  final String bundledAssetPath;
}

abstract interface class NaiveProxyBinaryBridge {
  String get bundledReleaseTag;

  Future<NaiveProxyInstallLayout> resolveInstallLayout();

  Future<Uint8List> loadBundledBinary(String assetPath);
}

class DefaultNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  const DefaultNaiveProxyBinaryBridge();

  @override
  String get bundledReleaseTag => naiveProxyPinnedReleaseTag;

  @override
  Future<NaiveProxyInstallLayout> resolveInstallLayout() async {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    NaiveProxyReleaseAsset? asset;
    for (final abi in deviceInfo.supportedAbis) {
      final candidate = naiveProxyReleaseAssets[abi];
      if (candidate != null) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      throw UnsupportedError(
        'naiveproxy is not packaged for Android ABIs: '
        '${deviceInfo.supportedAbis.join(', ')}',
      );
    }

    final homeDir = await appPath.homeDirPath;
    final runtimeDirectoryPath = path.join(
      homeDir,
      'runtimes',
      naiveProxyRuntimeDirectoryName,
      asset.abi,
    );

    return NaiveProxyInstallLayout(
      abi: asset.abi,
      runtimeDirectoryPath: runtimeDirectoryPath,
      executablePath:
          path.join(runtimeDirectoryPath, naiveProxyExecutableFileName),
      pendingPath: path.join(
        runtimeDirectoryPath,
        '$naiveProxyExecutableFileName.pending',
      ),
      rollbackPath: path.join(
        runtimeDirectoryPath,
        '$naiveProxyExecutableFileName.rollback',
      ),
      configPath: path.join(runtimeDirectoryPath, naiveProxyConfigFileName),
      versionPath: path.join(
        runtimeDirectoryPath,
        naiveProxyBundledVersionFileName,
      ),
      pendingVersionPath: path.join(
        runtimeDirectoryPath,
        naiveProxyPendingVersionFileName,
      ),
      bundledAssetPath: asset.bundledAssetPath,
    );
  }

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List();
  }
}

class _NaiveProxyCleanupFailure {
  const _NaiveProxyCleanupFailure({
    required this.message,
    required this.stackTrace,
  });

  final String message;
  final StackTrace stackTrace;
}

class NaiveProxyEngineAdapter implements EngineAdapter {
  const NaiveProxyEngineAdapter({
    this.core = const DefaultNaiveProxyCoreBridge(),
    this.lifecycle = const DefaultNaiveProxyLifecycleBridge(),
    this.platform = const DefaultNaiveProxyPlatformBridge(),
    this.process = const DefaultNaiveProxyProcessBridge(),
    this.binary = const DefaultNaiveProxyBinaryBridge(),
    this.waitForListener = _waitForNaiveProxyListener,
    required ReadNaiveProxyAccessControlCallback readAccessControl,
    ReadNaiveProxyProfileAccessControlCallback? readProfileAccessControl,
  })  : _readAccessControl = readAccessControl,
        _readProfileAccessControl = readProfileAccessControl;

  final NaiveProxyCoreBridge core;
  final NaiveProxyLifecycleBridge lifecycle;
  final NaiveProxyPlatformBridge platform;
  final NaiveProxyProcessBridge process;
  final NaiveProxyBinaryBridge binary;
  final WaitForNaiveProxyListenerCallback waitForListener;
  final ReadNaiveProxyAccessControlCallback _readAccessControl;
  final ReadNaiveProxyProfileAccessControlCallback? _readProfileAccessControl;

  AccessControl get _accessControl => _readAccessControl();
  AccessControl? get _profileAccessControl => _readProfileAccessControl?.call();

  @override
  Future<void> applyPendingUpdate() async {
    final layout = await binary.resolveInstallLayout();
    await Directory(layout.runtimeDirectoryPath).create(recursive: true);

    final active = File(layout.executablePath);
    final pending = File(layout.pendingPath);
    final rollback = File(layout.rollbackPath);
    final versionFile = File(layout.versionPath);
    final pendingVersionFile = File(layout.pendingVersionPath);

    if (pendingVersionFile.existsSync() && !pending.existsSync()) {
      await _deleteWithRetry(pendingVersionFile);
    }

    if (!active.existsSync() && !pending.existsSync()) {
      await _writeBundledBinary(layout, active);
      await _writeVersionFile(versionFile, binary.bundledReleaseTag);
      return;
    }

    final installedBundledTag = await _readVersionFile(versionFile);
    if (installedBundledTag != binary.bundledReleaseTag &&
        !pending.existsSync()) {
      await _writeBundledBinary(layout, pending);
      await _writeVersionFile(pendingVersionFile, binary.bundledReleaseTag);
    }

    if (!pending.existsSync()) {
      return;
    }

    final pendingBundledTag = await _readVersionFile(pendingVersionFile);
    var activeMovedToRollback = false;
    var pendingMovedToActive = false;

    try {
      await _deleteWithRetry(rollback);
      if (active.existsSync()) {
        await _renameWithRetry(active, rollback.path);
        activeMovedToRollback = true;
      }

      await _renameWithRetry(pending, active.path);
      pendingMovedToActive = true;

      if (pendingBundledTag != null) {
        await _writeVersionFile(versionFile, pendingBundledTag);
        await _deleteWithRetry(pendingVersionFile);
      }

      await _deleteWithRetry(rollback);
    } catch (e, stackTrace) {
      final rollbackFailure = await _rollbackPendingUpdate(
        active: active,
        pending: pending,
        rollback: rollback,
        activeMovedToRollback: activeMovedToRollback,
        pendingMovedToActive: pendingMovedToActive,
      );
      if (rollbackFailure != null) {
        Error.throwWithStackTrace(
          StateError(
            'Failed to apply pending naiveproxy update: $e. '
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
    try {
      if (await core.isInitialized()) {
        await core.shutdown();
      }
    } catch (e) {
      commonPrint.log("naiveproxy bridge shutdown before restart failed: $e");
    }

    try {
      await process.stopProcess();
    } catch (e) {
      commonPrint.log("naiveproxy process stop before restart failed: $e");
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
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) async {
    final configJson = runtimePlan.files[naiveProxyRuntimeArtifactConfigPath];
    if (configJson == null || configJson.isEmpty) {
      return 'naiveproxy runtime plan is missing config.json artifact.';
    }

    final layout = await binary.resolveInstallLayout();
    await Directory(layout.runtimeDirectoryPath).create(recursive: true);
    final configFile = File(layout.configPath);
    final wasProcessRunning = await process.readProcessStartTime() != null;
    final previousConfig =
        configFile.existsSync() ? await configFile.readAsString() : null;

    try {
      await configFile.writeAsString(configJson, flush: true);

      if (wasProcessRunning) {
        await process.stopProcess();
        final restarted = await process.startProcess(
          executablePath: layout.executablePath,
          workingDirectory: layout.runtimeDirectoryPath,
        );
        if (!restarted) {
          return _rollbackRuntimePlanUpdate(
            layout: layout,
            previousConfig: previousConfig,
            wasProcessRunning: wasProcessRunning,
            failureMessage:
                'naiveproxy process restart failed after config update.',
          );
        }
        await waitForListener(layout.configPath);
      }

      final message = await core.setupRuntimePlan(runtimePlan);
      if (message.isEmpty) {
        return '';
      }

      return _rollbackRuntimePlanUpdate(
        layout: layout,
        previousConfig: previousConfig,
        wasProcessRunning: wasProcessRunning,
        failureMessage: 'naiveproxy runtime plan update failed: $message',
      );
    } catch (e) {
      return _rollbackRuntimePlanUpdate(
        layout: layout,
        previousConfig: previousConfig,
        wasProcessRunning: wasProcessRunning,
        failureMessage: 'naiveproxy runtime plan update failed: $e',
      );
    }
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
        commonPrint.log("Failed to push naiveproxy notification title: $e");
      }
    }

    final layout = await binary.resolveInstallLayout();
    var processStarted = false;
    var listenerStarted = false;
    var vpnStartAttempted = false;

    try {
      processStarted = await process.startProcess(
        executablePath: layout.executablePath,
        workingDirectory: layout.runtimeDirectoryPath,
      );
      if (!processStarted) {
        return false;
      }

      await waitForListener(layout.configPath);

      await core.startListener();
      listenerStarted = true;

      if (await lifecycle.readBridgeStartTime() != null) {
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
        processStarted: processStarted,
        listenerStarted: listenerStarted,
        vpnStartAttempted: vpnStartAttempted,
      );
      if (rollbackFailure != null) {
        Error.throwWithStackTrace(
          StateError(
            'naiveproxy start failed: $e. '
            'Cleanup also failed: ${rollbackFailure.message}',
          ),
          rollbackFailure.stackTrace,
        );
      }
      Error.throwWithStackTrace(e, stackTrace);
    }

    final rollbackFailure = await _rollbackFailedStart(
      processStarted: processStarted,
      listenerStarted: listenerStarted,
      vpnStartAttempted: vpnStartAttempted,
    );
    if (rollbackFailure != null) {
      Error.throwWithStackTrace(
        StateError(
          'naiveproxy start returned false and cleanup failed: '
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
        commonPrint
            .log("Failed to stop VPN after naiveproxy listener stop error: $e");
      } else {
        error = e;
        stackTrace = s;
      }
    }

    try {
      await process.stopProcess();
    } catch (e, s) {
      if (error != null) {
        commonPrint.log(
            "Failed to stop naiveproxy process after earlier stop error: $e");
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
  Future<DateTime?> readStartTime() async =>
      await lifecycle.readBridgeStartTime() ??
      await process.readProcessStartTime();

  @override
  Future<void> persistColdStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  }) =>
      lifecycle.clearColdStartState();

  Future<String> _rollbackRuntimePlanUpdate({
    required NaiveProxyInstallLayout layout,
    required String? previousConfig,
    required bool wasProcessRunning,
    required String failureMessage,
  }) async {
    _NaiveProxyCleanupFailure? rollbackFailure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log("$message: $error");
      rollbackFailure ??= _NaiveProxyCleanupFailure(
        message: '$message: $error',
        stackTrace: stackTrace,
      );
    }

    if (wasProcessRunning) {
      try {
        await process.stopProcess();
      } catch (e, s) {
        captureFailure(
          'Failed to stop naiveproxy process during config rollback',
          e,
          s,
        );
      }
    }

    try {
      if (previousConfig == null) {
        await _deleteWithRetry(File(layout.configPath));
      } else {
        await File(layout.configPath)
            .writeAsString(previousConfig, flush: true);
      }
    } catch (e, s) {
      captureFailure(
        'Failed to restore previous naiveproxy config.json',
        e,
        s,
      );
    }

    if (wasProcessRunning) {
      if (previousConfig == null) {
        captureFailure(
          'Failed to restart previous naiveproxy process after config rollback',
          StateError('previous config.json is unavailable'),
          StackTrace.current,
        );
      } else {
        try {
          final restarted = await process.startProcess(
            executablePath: layout.executablePath,
            workingDirectory: layout.runtimeDirectoryPath,
          );
          if (!restarted) {
            captureFailure(
              'Failed to restart previous naiveproxy process after config rollback',
              StateError('startProcess returned false'),
              StackTrace.current,
            );
          } else {
            await waitForListener(layout.configPath);
          }
        } catch (e, s) {
          captureFailure(
            'Failed to restart previous naiveproxy process after config rollback',
            e,
            s,
          );
        }
      }
    }

    if (rollbackFailure == null) {
      return failureMessage;
    }
    return '$failureMessage Rollback failed: ${rollbackFailure!.message}';
  }

  Future<void> _writeBundledBinary(
    NaiveProxyInstallLayout layout,
    File target,
  ) async {
    try {
      final bytes = await binary.loadBundledBinary(layout.bundledAssetPath);
      await target.writeAsBytes(bytes, flush: true);
    } catch (e) {
      throw StateError(
        'Bundled naiveproxy asset ${layout.bundledAssetPath} is missing. '
        'Run `dart setup.dart android --out runtime-assets` first. $e',
      );
    }
  }

  Future<String?> _readVersionFile(File file) async {
    if (!file.existsSync()) {
      return null;
    }
    final content = (await file.readAsString()).trim();
    return content.isEmpty ? null : content;
  }

  Future<void> _writeVersionFile(File file, String version) =>
      file.writeAsString(version, flush: true);

  Future<_NaiveProxyCleanupFailure?> _rollbackPendingUpdate({
    required File active,
    required File pending,
    required File rollback,
    required bool activeMovedToRollback,
    required bool pendingMovedToActive,
  }) async {
    _NaiveProxyCleanupFailure? failure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log("$message: $error");
      failure ??= _NaiveProxyCleanupFailure(
        message: '$message: $error',
        stackTrace: stackTrace,
      );
    }

    try {
      if (pendingMovedToActive &&
          active.existsSync() &&
          !pending.existsSync()) {
        await _renameWithRetry(active, pending.path);
      }
    } catch (e, s) {
      captureFailure(
          'Failed to move new naiveproxy binary back to pending', e, s);
    }

    if (activeMovedToRollback) {
      try {
        if (rollback.existsSync()) {
          await _deleteWithRetry(active);
          await _renameWithRetry(rollback, active.path);
        }
      } catch (e, s) {
        captureFailure(
          'Failed to restore previous naiveproxy binary after update error',
          e,
          s,
        );
      } finally {
        try {
          await _deleteWithRetry(rollback);
        } catch (e, s) {
          captureFailure(
            'Failed to clean naiveproxy rollback binary after update error',
            e,
            s,
          );
        }
      }
    }

    return failure;
  }

  Future<_NaiveProxyCleanupFailure?> _rollbackFailedStart({
    required bool processStarted,
    required bool listenerStarted,
    required bool vpnStartAttempted,
  }) async {
    _NaiveProxyCleanupFailure? failure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log("$message: $error");
      failure ??= _NaiveProxyCleanupFailure(
        message: '$message: $error',
        stackTrace: stackTrace,
      );
    }

    if (vpnStartAttempted) {
      try {
        await platform.stopVpn();
      } catch (e, s) {
        captureFailure('Failed to stop VPN during naiveproxy rollback', e, s);
      }
    }

    if (listenerStarted) {
      try {
        await core.stopListener();
      } catch (e, s) {
        captureFailure(
            'Failed to stop listener during naiveproxy rollback', e, s);
      }
    }

    if (processStarted) {
      try {
        await process.stopProcess();
      } catch (e, s) {
        captureFailure(
            'Failed to stop naiveproxy process during rollback', e, s);
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

  static Future<void> _waitForNaiveProxyListener(String configPath) async {
    final configFile = File(configPath);
    if (!configFile.existsSync()) {
      throw StateError('naiveproxy config.json is missing at $configPath');
    }

    final config = json.decode(await configFile.readAsString());
    if (config is! Map<String, dynamic>) {
      throw StateError('naiveproxy config.json is invalid at $configPath');
    }

    final listen = config['listen'];
    if (listen is! String || listen.isEmpty) {
      throw StateError('naiveproxy config.json is missing a listen URI.');
    }

    final listenUri = Uri.parse(listen);
    final port = listenUri.port;
    if (port <= 0) {
      throw StateError('naiveproxy listen URI must contain a TCP port.');
    }

    final host = listenUri.host.isEmpty ? localhost : listenUri.host;
    final deadline = DateTime.now().add(const Duration(seconds: 5));

    while (DateTime.now().isBefore(deadline)) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 250),
        );
        await socket.close();
        return;
      } catch (_) {
        await socket?.close();
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }

    throw StateError(
      'naiveproxy did not open $host:$port within the start timeout.',
    );
  }
}
