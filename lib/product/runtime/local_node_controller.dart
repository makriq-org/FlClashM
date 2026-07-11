import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';

import 'built_in_proxy_types.dart';

typedef LocalNodeWaitForRuntimeNodeListenerCallback = Future<void> Function(
  String host,
  int port,
);

@immutable
class LocalNodeSharedInstallLayout {
  const LocalNodeSharedInstallLayout({
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
class LocalNodeLayout {
  const LocalNodeLayout({
    required this.nodeId,
    required this.workingDirectoryPath,
    required this.configPath,
  });

  final String nodeId;
  final String workingDirectoryPath;
  final String configPath;
}

abstract class LocalNodeBinaryBridge<
    TSharedLayout extends LocalNodeSharedInstallLayout> {
  String get bundledReleaseTag;

  Future<TSharedLayout> resolveSharedInstallLayout();

  Future<Uint8List> loadBundledBinary(String assetPath);
}

enum LocalNodeStartMode {
  sequential,
  parallel,
}

@immutable
class LocalNodeColdStartExtras {
  const LocalNodeColdStartExtras({
    this.extraFields = const {},
  }) : includeNode = true;

  const LocalNodeColdStartExtras.skip()
      : includeNode = false,
        extraFields = const {};

  final bool includeNode;
  final Map<String, dynamic> extraFields;
}

@immutable
class LocalNodeMutation<TNodeLayout extends LocalNodeLayout> {
  const LocalNodeMutation({
    required this.plan,
    required this.previousPlan,
    required this.layout,
    required this.previousConfig,
    required this.wasRunning,
  });

  final BuiltInProxyNodePlan plan;
  final BuiltInProxyNodePlan? previousPlan;
  final TNodeLayout layout;
  final String? previousConfig;
  final bool wasRunning;
}

@immutable
class LocalNodeStageState<TNodeLayout extends LocalNodeLayout> {
  const LocalNodeStageState({
    required this.mutations,
    required this.removedPlans,
  });

  final List<LocalNodeMutation<TNodeLayout>> mutations;
  final List<BuiltInProxyNodePlan> removedPlans;
}

class _LocalNodeCleanupFailure {
  const _LocalNodeCleanupFailure({
    required this.message,
    required this.stackTrace,
  });

  final String message;
  final StackTrace stackTrace;
}

abstract class LocalNodeController<
    TSharedLayout extends LocalNodeSharedInstallLayout,
    TNodeLayout extends LocalNodeLayout> {
  LocalNodeController({
    required this.typeLabel,
    required this.configArtifactName,
    required this.binary,
    required this.runtime,
    required this.waitForListener,
    this.startMode = LocalNodeStartMode.sequential,
  });

  final String typeLabel;
  final String configArtifactName;
  final LocalNodeBinaryBridge<TSharedLayout> binary;
  final RuntimeNodePlatformBridge runtime;
  final LocalNodeWaitForRuntimeNodeListenerCallback waitForListener;
  final LocalNodeStartMode startMode;

  LocalNodeStageState<TNodeLayout>? _stagedState;

  Future<void> applyPendingUpdate() async {
    final layout = await binary.resolveSharedInstallLayout();
    await Directory(layout.runtimeRootPath).create(recursive: true);
    await Directory(layout.nodesDirectoryPath).create(recursive: true);
  }

  Future<String> stageRuntimePlan({
    required List<BuiltInProxyNodePlan> currentPlans,
    required List<BuiltInProxyNodePlan> nextPlans,
  }) async {
    if (_stagedState != null) {
      return '$typeLabel runtime plan stage is already active.';
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
    final mutations = <LocalNodeMutation<TNodeLayout>>[];

    try {
      for (final plan in nextPlans) {
        final layout = resolveNodeLayout(sharedLayout, plan.nodeId);
        final config = readConfigArtifact(plan);
        final configFile = File(layout.configPath);
        final previousConfig =
            configFile.existsSync() ? await configFile.readAsString() : null;
        final wasRunning =
            await runtime.readNodeStartTime(nodeId: plan.nodeId) != null;
        final previousPlan = currentById[plan.nodeId];

        final configChanged = previousConfig != config;
        final isNewPlan = previousPlan == null;
        if (!isNewPlan && !configChanged) {
          continue;
        }

        mutations.add(
          LocalNodeMutation<TNodeLayout>(
            plan: plan,
            previousPlan: previousPlan,
            layout: layout,
            previousConfig: previousConfig,
            wasRunning: wasRunning,
          ),
        );

        await Directory(layout.workingDirectoryPath).create(recursive: true);
        await configFile.writeAsString(config, flush: true);

        if (wasRunning) {
          await runtime.stopNode(nodeId: plan.nodeId);
          final started = await startPlan(sharedLayout, plan, layout);
          if (!started) {
            return rollbackStageFailure(
              mutations: mutations,
              failureMessage:
                  '$typeLabel node `${plan.name}` failed to restart after config update.',
            );
          }
          await confirmStageRestart(plan);
        }
      }
    } catch (e) {
      return rollbackStageFailure(
        mutations: mutations,
        failureMessage: '$typeLabel runtime plan staging failed: $e',
      );
    }

    _stagedState = LocalNodeStageState<TNodeLayout>(
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
    final failureMessage = '$typeLabel runtime plan rollback failed.';
    final message = await rollbackStageFailure(
      mutations: stagedState.mutations,
      failureMessage: failureMessage,
    );
    _stagedState = null;
    return message == failureMessage ? '' : message;
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
      final layout = resolveNodeLayout(sharedLayout, removedPlan.nodeId);
      await deleteDirectoryIfExists(Directory(layout.workingDirectoryPath));
    }
  }

  Future<bool> startNodes(List<BuiltInProxyNodePlan> plans) async {
    if (plans.isEmpty) {
      return true;
    }

    final sharedLayout = await binary.resolveSharedInstallLayout();
    final startedNodes = <BuiltInProxyNodePlan>[];
    try {
      if (startMode == LocalNodeStartMode.parallel) {
        final started = await Future.wait([
          for (final plan in plans)
            _startNodePlan(
              sharedLayout: sharedLayout,
              plan: plan,
              startedNodes: startedNodes,
            ),
        ]);
        if (started.every((value) => value)) {
          return true;
        }
        await stopStartedNodes(startedNodes);
        return false;
      }

      for (final plan in plans) {
        final started = await _startNodePlan(
          sharedLayout: sharedLayout,
          plan: plan,
          startedNodes: startedNodes,
        );
        if (!started) {
          await stopStartedNodes(startedNodes);
          return false;
        }
      }
      return true;
    } catch (e, stackTrace) {
      await handleStartNodesException(
        error: e,
        stackTrace: stackTrace,
        startedNodes: startedNodes,
      );
      rethrow;
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
    final nodes = <Map<String, dynamic>>[];
    for (final plan in plans) {
      final layout = resolveNodeLayout(sharedLayout, plan.nodeId);
      final extras = await buildColdStartExtras(plan, sharedLayout, layout);
      if (!extras.includeNode) {
        continue;
      }
      nodes.add(
        <String, dynamic>{
          'nodeId': plan.nodeId,
          'type': plan.type.label,
          'name': plan.name,
          'host': plan.listenHost,
          'port': plan.listenPort,
          'executablePath': sharedLayout.executablePath,
          'workingDirectory': layout.workingDirectoryPath,
          ...extras.extraFields,
        },
      );
    }
    return nodes;
  }

  Future<void> saveColdStartNodes(List<Map<String, dynamic>> nodes) async {
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
      return;
    }
    final manifest = <String, dynamic>{'nodes': nodes};
    await runtime.saveColdStartNodes(json.encode(manifest));
  }

  @protected
  TNodeLayout resolveNodeLayout(TSharedLayout sharedLayout, String nodeId);

  @protected
  String readConfigArtifact(BuiltInProxyNodePlan plan);

  @protected
  Future<bool> startPlan(
    TSharedLayout sharedLayout,
    BuiltInProxyNodePlan plan,
    TNodeLayout layout,
  );

  @protected
  Future<void> confirmStartedNode(BuiltInProxyNodePlan plan) async {
    Object? listenerError;
    StackTrace? listenerStackTrace;
    var listenerReady = false;
    var listenerCompleted = false;
    unawaited(
      waitForListener(plan.listenHost, plan.listenPort).then((_) {
        listenerReady = true;
        listenerCompleted = true;
      }).catchError((Object error, StackTrace stackTrace) {
        listenerError = error;
        listenerStackTrace = stackTrace;
        listenerCompleted = true;
      }),
    );

    var missingProcessChecks = 0;
    while (!listenerCompleted) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (await runtime.readNodeStartTime(nodeId: plan.nodeId) != null) {
        missingProcessChecks = 0;
        continue;
      }
      final processError = await runtime.readNodeLastError(nodeId: plan.nodeId);
      if (processError == null && ++missingProcessChecks < 3) {
        continue;
      }
      throw StateError(
        '$typeLabel node `${plan.name}` exited before its local listener was ready'
        '${processError == null ? '.' : ': $processError'}',
      );
    }

    if (listenerReady) {
      return;
    }
    if (listenerError != null) {
      Error.throwWithStackTrace(
        listenerError!,
        listenerStackTrace ?? StackTrace.current,
      );
    }
    throw StateError('$typeLabel node `${plan.name}` listener check failed.');
  }

  @protected
  Future<void> confirmStageRestart(BuiltInProxyNodePlan plan) =>
      confirmStartedNode(plan);

  @protected
  Future<LocalNodeColdStartExtras> buildColdStartExtras(
    BuiltInProxyNodePlan plan,
    TSharedLayout sharedLayout,
    TNodeLayout layout,
  ) async =>
      const LocalNodeColdStartExtras();

  @protected
  Future<String> rollbackStageFailure({
    required List<LocalNodeMutation<TNodeLayout>> mutations,
    required String failureMessage,
  });

  @protected
  Future<void> handleStartNodesException({
    required Object error,
    required StackTrace stackTrace,
    required List<BuiltInProxyNodePlan> startedNodes,
  }) =>
      stopStartedNodes(startedNodes);

  @protected
  Future<String> rollbackStageFailureWithRestart({
    required List<LocalNodeMutation<TNodeLayout>> mutations,
    required String failureMessage,
  }) async {
    _LocalNodeCleanupFailure? rollbackFailure;

    void captureFailure(
      String message,
      Object error,
      StackTrace stackTrace,
    ) {
      commonPrint.log('$message: $error');
      rollbackFailure ??= _LocalNodeCleanupFailure(
        message: '$message: $error',
        stackTrace: stackTrace,
      );
    }

    for (final mutation in mutations.reversed) {
      try {
        await runtime.stopNode(nodeId: mutation.plan.nodeId);
      } catch (e, s) {
        captureFailure(
          'Failed to stop $typeLabel node during rollback',
          e,
          s,
        );
      }

      try {
        final configFile = File(mutation.layout.configPath);
        if (mutation.previousConfig == null) {
          await deleteFileWithRetry(configFile);
          await deleteDirectoryIfExists(
            Directory(mutation.layout.workingDirectoryPath),
          );
        } else {
          await configFile.writeAsString(mutation.previousConfig!, flush: true);
        }
      } catch (e, s) {
        captureFailure(
          'Failed to restore previous $typeLabel node $configArtifactName',
          e,
          s,
        );
      }

      if (mutation.wasRunning) {
        try {
          final sharedLayout = await binary.resolveSharedInstallLayout();
          final rollbackPlan = mutation.previousPlan ?? mutation.plan;
          final restarted = await startPlan(
            sharedLayout,
            rollbackPlan,
            mutation.layout,
          );
          if (!restarted) {
            captureFailure(
              'Failed to restart previous $typeLabel node during rollback',
              StateError('startNode returned false'),
              StackTrace.current,
            );
          } else {
            await confirmStartedNode(rollbackPlan);
          }
        } catch (e, s) {
          captureFailure(
            'Failed to restart previous $typeLabel node during rollback',
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

  @protected
  Future<void> rethrowStartNodesExceptionWithCleanup({
    required Object error,
    required StackTrace stackTrace,
    required List<BuiltInProxyNodePlan> startedNodes,
  }) async {
    final rollbackFailure = await _rollbackFailedStart(startedNodes);
    if (rollbackFailure != null) {
      Error.throwWithStackTrace(
        StateError(
          '$typeLabel node start failed: $error. '
          'Cleanup also failed: ${rollbackFailure.message}',
        ),
        rollbackFailure.stackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }

  @protected
  Future<void> stopStartedNodes(List<BuiltInProxyNodePlan> plans) async {
    for (final plan in plans.reversed) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e) {
        commonPrint.log(
          'Failed to stop $typeLabel node `${plan.name}` during start rollback: $e',
        );
      }
    }
  }

  @protected
  Future<void> deleteFileWithRetry(File file) async {
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

  @protected
  Future<void> deleteDirectoryIfExists(Directory directory) async {
    if (!directory.existsSync()) {
      return;
    }
    await directory.delete(recursive: true);
  }

  Future<bool> _startNodePlan({
    required TSharedLayout sharedLayout,
    required BuiltInProxyNodePlan plan,
    required List<BuiltInProxyNodePlan> startedNodes,
  }) async {
    final alreadyRunning =
        await runtime.readNodeStartTime(nodeId: plan.nodeId) != null;
    if (!alreadyRunning) {
      final layout = resolveNodeLayout(sharedLayout, plan.nodeId);
      final started = await startPlan(sharedLayout, plan, layout);
      if (!started) {
        return false;
      }
      startedNodes.add(plan);
    }
    await confirmStartedNode(plan);
    return true;
  }

  Future<_LocalNodeCleanupFailure?> _rollbackFailedStart(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    _LocalNodeCleanupFailure? failure;
    for (final plan in plans.reversed) {
      try {
        await runtime.stopNode(nodeId: plan.nodeId);
      } catch (e, s) {
        failure ??= _LocalNodeCleanupFailure(
          message:
              'Failed to stop $typeLabel node `${plan.name}` during rollback: $e',
          stackTrace: s,
        );
      }
    }
    return failure;
  }
}
