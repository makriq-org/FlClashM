import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'built_in_proxy_types.dart';
import 'olcrtc_release.dart';

typedef OlcRtcWaitForRuntimeNodeListenerCallback = Future<void> Function(
  String host,
  int port,
);

@immutable
class OlcRtcSharedInstallLayout {
  const OlcRtcSharedInstallLayout({
    required this.abi,
    required this.runtimeRootPath,
    required this.nodesDirectoryPath,
    required this.executablePath,
    required this.pendingPath,
    required this.rollbackPath,
    required this.versionPath,
    required this.pendingVersionPath,
    required this.bundledAssetPath,
    this.managedBinaryUpdateEnabled = true,
  });

  final String abi;
  final String runtimeRootPath;
  final String nodesDirectoryPath;
  final String executablePath;
  final String pendingPath;
  final String rollbackPath;
  final String versionPath;
  final String pendingVersionPath;
  final String bundledAssetPath;
  final bool managedBinaryUpdateEnabled;
}

@immutable
class OlcRtcNodeLayout {
  const OlcRtcNodeLayout({
    required this.nodeId,
    required this.workingDirectoryPath,
    required this.configPath,
  });

  final String nodeId;
  final String workingDirectoryPath;
  final String configPath;
}

abstract interface class OlcRtcBinaryBridge {
  String get bundledReleaseTag;

  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout();

  Future<Uint8List> loadBundledBinary(String assetPath);
}

class DefaultOlcRtcBinaryBridge implements OlcRtcBinaryBridge {
  const DefaultOlcRtcBinaryBridge({
    this.nativeLibrary = const AndroidRuntimeNodeNativeLibraryBridge(),
  });

  final AndroidRuntimeNodeNativeLibraryBridge nativeLibrary;

  @override
  String get bundledReleaseTag => olcRtcPinnedReleaseTag;

  @override
  Future<OlcRtcSharedInstallLayout> resolveSharedInstallLayout() async {
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    OlcRtcReleaseAsset? asset;
    for (final abi in deviceInfo.supportedAbis) {
      final candidate = olcRtcReleaseAssets[abi];
      if (candidate != null) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      throw UnsupportedError(
        'olcrtc is not packaged for Android ABIs: '
        '${deviceInfo.supportedAbis.join(', ')}',
      );
    }

    final homeDir = await appPath.homeDirPath;
    final runtimeRootPath = path.join(
      homeDir,
      'runtimes',
      olcRtcRuntimeDirectoryName,
      asset.abi,
    );
    final executablePath = await nativeLibrary.resolvePath(
      olcRtcAndroidNativeLibraryFileName,
    );
    if (executablePath == null) {
      throw StateError(
        'Bundled native olcrtc library $olcRtcAndroidNativeLibraryFileName '
        'is missing. Run `dart setup.dart android --out runtime-assets` '
        'before building.',
      );
    }

    return OlcRtcSharedInstallLayout(
      abi: asset.abi,
      runtimeRootPath: runtimeRootPath,
      nodesDirectoryPath: path.join(runtimeRootPath, 'nodes'),
      executablePath: executablePath,
      pendingPath: path.join(
        runtimeRootPath,
        '$olcRtcExecutableFileName.pending',
      ),
      rollbackPath: path.join(
        runtimeRootPath,
        '$olcRtcExecutableFileName.rollback',
      ),
      versionPath: path.join(
        runtimeRootPath,
        olcRtcBundledVersionFileName,
      ),
      pendingVersionPath: path.join(
        runtimeRootPath,
        olcRtcPendingVersionFileName,
      ),
      bundledAssetPath: asset.bundledAssetPath,
      managedBinaryUpdateEnabled: false,
    );
  }

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List();
  }
}

class _OlcRtcCleanupFailure {
  const _OlcRtcCleanupFailure({
    required this.message,
    required this.stackTrace,
  });

  final String message;
  final StackTrace stackTrace;
}

@immutable
class _OlcRtcNodeMutation {
  const _OlcRtcNodeMutation({
    required this.plan,
    required this.previousPlan,
    required this.layout,
    required this.previousConfig,
    required this.wasRunning,
  });

  final BuiltInProxyNodePlan plan;
  final BuiltInProxyNodePlan? previousPlan;
  final OlcRtcNodeLayout layout;
  final String? previousConfig;
  final bool wasRunning;
}

@immutable
class _OlcRtcStageState {
  const _OlcRtcStageState({
    required this.previousPlans,
    required this.nextPlans,
    required this.mutations,
    required this.removedPlans,
  });

  final List<BuiltInProxyNodePlan> previousPlans;
  final List<BuiltInProxyNodePlan> nextPlans;
  final List<_OlcRtcNodeMutation> mutations;
  final List<BuiltInProxyNodePlan> removedPlans;
}

class OlcRtcNodeController {
  OlcRtcNodeController({
    this.binary = const DefaultOlcRtcBinaryBridge(),
    this.runtime = const AndroidRuntimeNodeBridge(),
    this.waitForListener = _waitForRuntimeNodeListener,
  });

  final OlcRtcBinaryBridge binary;
  final RuntimeNodePlatformBridge runtime;
  final OlcRtcWaitForRuntimeNodeListenerCallback waitForListener;

  _OlcRtcStageState? _stagedState;

  Future<void> applyPendingUpdate() async {
    final layout = await binary.resolveSharedInstallLayout();
    await Directory(layout.runtimeRootPath).create(recursive: true);
    await Directory(layout.nodesDirectoryPath).create(recursive: true);
    if (!layout.managedBinaryUpdateEnabled) {
      return;
    }

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
            'Failed to apply pending olcrtc update: $e. '
            'Rollback also failed: ${rollbackFailure.message}',
          ),
          rollbackFailure.stackTrace,
        );
      }
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  Future<String> stageRuntimePlan({
    required List<BuiltInProxyNodePlan> currentPlans,
    required List<BuiltInProxyNodePlan> nextPlans,
  }) async {
    if (_stagedState != null) {
      return 'olcrtc runtime plan stage is already active.';
    }

    final sharedLayout = await binary.resolveSharedInstallLayout();
    await Directory(sharedLayout.runtimeRootPath).create(recursive: true);
    await Directory(sharedLayout.nodesDirectoryPath).create(recursive: true);

    final currentById = {
      for (final plan in currentPlans) plan.nodeId: plan,
    };
    final nextById = {
      for (final plan in nextPlans) plan.nodeId: plan,
    };
    final mutations = <_OlcRtcNodeMutation>[];

    try {
      for (final plan in nextPlans) {
        final layout = _resolveNodeLayout(sharedLayout, plan.nodeId);
        final configYaml = _readConfigArtifact(plan);
        final configFile = File(layout.configPath);
        final previousConfig =
            configFile.existsSync() ? await configFile.readAsString() : null;
        final wasRunning =
            await runtime.readNodeStartTime(nodeId: plan.nodeId) != null;
        final previousPlan = currentById[plan.nodeId];

        final configChanged = previousConfig != configYaml;
        final isNewPlan = previousPlan == null;
        if (!isNewPlan && !configChanged) {
          continue;
        }

        mutations.add(
          _OlcRtcNodeMutation(
            plan: plan,
            previousPlan: previousPlan,
            layout: layout,
            previousConfig: previousConfig,
            wasRunning: wasRunning,
          ),
        );

        await Directory(layout.workingDirectoryPath).create(recursive: true);
        await configFile.writeAsString(configYaml, flush: true);

        if (wasRunning) {
          await runtime.stopNode(nodeId: plan.nodeId);
          final started = await runtime.startNode(
            nodeId: plan.nodeId,
            executablePath: sharedLayout.executablePath,
            workingDirectory: layout.workingDirectoryPath,
            arguments: _buildArguments(layout),
          );
          if (!started) {
            return _rollbackStageFailure(
              mutations: mutations,
              failureMessage:
                  'olcrtc node `${plan.name}` failed to restart after config update.',
            );
          }
          await waitForListener(plan.listenHost, plan.listenPort);
        }
      }
    } catch (e) {
      return _rollbackStageFailure(
        mutations: mutations,
        failureMessage: 'olcrtc runtime plan staging failed: $e',
      );
    }

    _stagedState = _OlcRtcStageState(
      previousPlans: currentPlans,
      nextPlans: nextPlans,
      mutations: mutations,
      removedPlans: [
        for (final plan in currentPlans)
          if (!nextById.containsKey(plan.nodeId)) plan,
      ],
    );
    return '';
  }

  Future<String> rollbackStagedRuntimePlan() async {
    final stagedState = _stagedState;
    if (stagedState == null) {
      return '';
    }
    final message = await _rollbackStageFailure(
      mutations: stagedState.mutations,
      failureMessage: 'olcrtc runtime plan rollback failed.',
    );
    _stagedState = null;
    return message == 'olcrtc runtime plan rollback failed.' ? '' : message;
  }

  Future<void> commitStagedRuntimePlan() async {
    final stagedState = _stagedState;
    if (stagedState == null) {
      return;
    }
    _stagedState = null;

    for (final removedPlan in stagedState.removedPlans) {
      await runtime.stopNode(nodeId: removedPlan.nodeId);
      final sharedLayout = await binary.resolveSharedInstallLayout();
      final layout = _resolveNodeLayout(sharedLayout, removedPlan.nodeId);
      await _deleteDirectoryIfExists(Directory(layout.workingDirectoryPath));
    }
  }

  Future<bool> startNodes(List<BuiltInProxyNodePlan> plans) async {
    if (plans.isEmpty) {
      return true;
    }

    final sharedLayout = await binary.resolveSharedInstallLayout();
    final startedNodes = <BuiltInProxyNodePlan>[];
    try {
      for (final plan in plans) {
        final alreadyRunning =
            await runtime.readNodeStartTime(nodeId: plan.nodeId) != null;
        if (!alreadyRunning) {
          final layout = _resolveNodeLayout(sharedLayout, plan.nodeId);
          final started = await runtime.startNode(
            nodeId: plan.nodeId,
            executablePath: sharedLayout.executablePath,
            workingDirectory: layout.workingDirectoryPath,
            arguments: _buildArguments(layout),
          );
          if (!started) {
            await _stopStartedNodes(startedNodes);
            return false;
          }
          startedNodes.add(plan);
        }
        await waitForListener(plan.listenHost, plan.listenPort);
      }
      return true;
    } catch (e, stackTrace) {
      final rollbackFailure = await _rollbackFailedStart(startedNodes);
      if (rollbackFailure != null) {
        Error.throwWithStackTrace(
          StateError(
            'olcrtc node start failed: $e. '
            'Cleanup also failed: ${rollbackFailure.message}',
          ),
          rollbackFailure.stackTrace,
        );
      }
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  Future<void> stopNodes(List<BuiltInProxyNodePlan> plans) async {
    Object? error;
    StackTrace? stackTrace;
    for (final plan in plans) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e, s) {
        error ??= e;
        stackTrace ??= s;
      }
    }
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  Future<void> persistColdStart(List<BuiltInProxyNodePlan> plans) async {
    final nodes = await buildColdStartNodes(plans);
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
      return;
    }

    await saveColdStartNodes(nodes);
  }

  Future<List<Map<String, dynamic>>> buildColdStartNodes(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    if (plans.isEmpty) {
      return const [];
    }
    final sharedLayout = await binary.resolveSharedInstallLayout();
    return [
      for (final plan in plans)
        <String, dynamic>{
          'nodeId': plan.nodeId,
          'type': plan.type.label,
          'name': plan.name,
          'host': plan.listenHost,
          'port': plan.listenPort,
          'executablePath': sharedLayout.executablePath,
          'workingDirectory': _resolveNodeLayout(sharedLayout, plan.nodeId)
              .workingDirectoryPath,
          'arguments': _buildArguments(
            _resolveNodeLayout(sharedLayout, plan.nodeId),
          ),
        },
    ];
  }

  Future<void> saveColdStartNodes(List<Map<String, dynamic>> nodes) async {
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
      return;
    }
    final manifest = <String, dynamic>{'nodes': nodes};
    await runtime.saveColdStartNodes(json.encode(manifest));
  }

  String _readConfigArtifact(BuiltInProxyNodePlan plan) {
    final configYaml =
        plan.files['built-in-proxies/olcrtc/${plan.nodeId}/config.yaml'];
    if (configYaml == null || configYaml.isEmpty) {
      throw StateError(
        'olcrtc node `${plan.name}` is missing config.yaml artifact.',
      );
    }
    return configYaml;
  }

  List<String> _buildArguments(OlcRtcNodeLayout layout) => [layout.configPath];

  OlcRtcNodeLayout _resolveNodeLayout(
    OlcRtcSharedInstallLayout sharedLayout,
    String nodeId,
  ) {
    final workingDirectoryPath =
        path.join(sharedLayout.nodesDirectoryPath, nodeId);
    return OlcRtcNodeLayout(
      nodeId: nodeId,
      workingDirectoryPath: workingDirectoryPath,
      configPath: path.join(workingDirectoryPath, olcRtcConfigFileName),
    );
  }

  Future<String> _rollbackStageFailure({
    required List<_OlcRtcNodeMutation> mutations,
    required String failureMessage,
  }) async {
    _OlcRtcCleanupFailure? rollbackFailure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log('$message: $error');
      rollbackFailure ??= _OlcRtcCleanupFailure(
        message: '$message: $error',
        stackTrace: stackTrace,
      );
    }

    for (final mutation in mutations.reversed) {
      try {
        await runtime.stopNode(nodeId: mutation.plan.nodeId);
      } catch (e, s) {
        captureFailure(
          'Failed to stop olcrtc node during rollback',
          e,
          s,
        );
      }

      try {
        final configFile = File(mutation.layout.configPath);
        if (mutation.previousConfig == null) {
          await _deleteWithRetry(configFile);
          await _deleteDirectoryIfExists(
            Directory(mutation.layout.workingDirectoryPath),
          );
        } else {
          await configFile.writeAsString(mutation.previousConfig!, flush: true);
        }
      } catch (e, s) {
        captureFailure(
          'Failed to restore previous olcrtc node config.yaml',
          e,
          s,
        );
      }

      if (mutation.wasRunning) {
        try {
          final sharedLayout = await binary.resolveSharedInstallLayout();
          final rollbackPlan = mutation.previousPlan ?? mutation.plan;
          final restarted = await runtime.startNode(
            nodeId: mutation.plan.nodeId,
            executablePath: sharedLayout.executablePath,
            workingDirectory: mutation.layout.workingDirectoryPath,
            arguments: _buildArguments(mutation.layout),
          );
          if (!restarted) {
            captureFailure(
              'Failed to restart previous olcrtc node during rollback',
              StateError('startNode returned false'),
              StackTrace.current,
            );
          } else {
            await waitForListener(
              rollbackPlan.listenHost,
              rollbackPlan.listenPort,
            );
          }
        } catch (e, s) {
          captureFailure(
            'Failed to restart previous olcrtc node during rollback',
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

  Future<void> _stopStartedNodes(List<BuiltInProxyNodePlan> plans) async {
    for (final plan in plans.reversed) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e) {
        commonPrint.log(
          'Failed to stop olcrtc node `${plan.name}` during start rollback: $e',
        );
      }
    }
  }

  Future<_OlcRtcCleanupFailure?> _rollbackFailedStart(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    _OlcRtcCleanupFailure? failure;
    for (final plan in plans.reversed) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e, s) {
        failure ??= _OlcRtcCleanupFailure(
          message:
              'Failed to stop olcrtc node `${plan.name}` during rollback: $e',
          stackTrace: s,
        );
      }
    }
    return failure;
  }

  Future<void> _writeBundledBinary(
    OlcRtcSharedInstallLayout layout,
    File target,
  ) async {
    try {
      final bytes = await binary.loadBundledBinary(layout.bundledAssetPath);
      await target.writeAsBytes(bytes, flush: true);
    } catch (e) {
      throw StateError(
        'Bundled olcrtc asset ${layout.bundledAssetPath} is missing. '
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

  Future<_OlcRtcCleanupFailure?> _rollbackPendingUpdate({
    required File active,
    required File pending,
    required File rollback,
    required bool activeMovedToRollback,
    required bool pendingMovedToActive,
  }) async {
    _OlcRtcCleanupFailure? failure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log('$message: $error');
      failure ??= _OlcRtcCleanupFailure(
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
      captureFailure('Failed to move new olcrtc binary back to pending', e, s);
    }

    if (activeMovedToRollback) {
      try {
        if (rollback.existsSync()) {
          await _deleteWithRetry(active);
          await _renameWithRetry(rollback, active.path);
        }
      } catch (e, s) {
        captureFailure(
          'Failed to restore previous olcrtc binary after update error',
          e,
          s,
        );
      } finally {
        try {
          await _deleteWithRetry(rollback);
        } catch (e, s) {
          captureFailure(
            'Failed to clean olcrtc rollback binary after update error',
            e,
            s,
          );
        }
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

  Future<void> _deleteDirectoryIfExists(Directory directory) async {
    if (!directory.existsSync()) {
      return;
    }
    await directory.delete(recursive: true);
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

  static Future<void> _waitForRuntimeNodeListener(
    String host,
    int port,
  ) async {
    final uri = Uri(
      scheme: 'socks5',
      host: host,
      port: port,
    );
    // OlcRTC can finish ICE before the datachannel-backed SOCKS listener is
    // ready, especially on a cold Android emulator.
    for (var attempt = 0; attempt < 240; attempt++) {
      try {
        final socket = await Socket.connect(
          uri.host,
          uri.port,
          timeout: const Duration(milliseconds: 250),
        );
        await socket.close();
        return;
      } catch (_) {
        if (attempt == 239) {
          throw StateError(
            'Timed out waiting for local runtime node listener on '
            '${uri.host}:${uri.port}.',
          );
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
  }
}
