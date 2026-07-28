import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/android/android_runtime_node_bridge.dart';
import 'package:flutter/foundation.dart';

import 'built_in_proxy_types.dart';

@immutable
class LocalNodeSharedInstallLayout {
  const LocalNodeSharedInstallLayout({
    required this.abi,
    required this.runtimeRootPath,
    required this.nodesDirectoryPath,
    required this.executablePath,
  });

  final String abi;
  final String runtimeRootPath;
  final String nodesDirectoryPath;
  final String executablePath;
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
  Future<TSharedLayout> resolveSharedInstallLayout();
}

@immutable
class LocalNodeLaunchExtras {
  const LocalNodeLaunchExtras({
    this.includeNode = true,
    this.fields = const {},
  });

  const LocalNodeLaunchExtras.skip()
      : includeNode = false,
        fields = const {};

  final bool includeNode;
  final Map<String, dynamic> fields;
}

@immutable
class LocalNodeMutation<TNodeLayout extends LocalNodeLayout> {
  const LocalNodeMutation({
    required this.plan,
    required this.layout,
    required this.previousConfig,
    this.previousArtifacts = const {},
  });

  final BuiltInProxyNodePlan plan;
  final TNodeLayout layout;
  final String? previousConfig;

  /// Contents of every extra artifact before staging, keyed by the path
  /// relative to the node working directory. A `null` value means the file did
  /// not exist and must be removed again on rollback.
  final Map<String, String?> previousArtifacts;
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

abstract class LocalNodeController<
    TSharedLayout extends LocalNodeSharedInstallLayout,
    TNodeLayout extends LocalNodeLayout> {
  LocalNodeController({
    required this.typeLabel,
    required this.configArtifactName,
    required this.binary,
    required this.runtime,
  });

  final String typeLabel;
  final String configArtifactName;
  final LocalNodeBinaryBridge<TSharedLayout> binary;
  final RuntimeNodePlatformBridge runtime;

  LocalNodeStageState<TNodeLayout>? _stagedState;
  Future<TSharedLayout>? _sharedInstallLayout;

  /// The device ABI and the bundled binary path behind the shared layout cannot
  /// change while the process lives, yet resolving them costs several platform
  /// round-trips — and one plan application asks for the layout three times per
  /// node type. The answer is therefore memoized.
  ///
  /// Only a successful resolution is kept. A missing ABI or a missing binary
  /// must stay reportable on the next attempt, and callers racing on the first
  /// resolution share one in-flight future instead of starting a second one.
  @protected
  Future<TSharedLayout> resolveSharedInstallLayout() {
    final cached = _sharedInstallLayout;
    if (cached != null) return cached;
    late final Future<TSharedLayout> pending;
    pending = Future<TSharedLayout>.microtask(() async {
      try {
        return await binary.resolveSharedInstallLayout();
      } catch (_) {
        if (identical(_sharedInstallLayout, pending)) {
          _sharedInstallLayout = null;
        }
        rethrow;
      }
    });
    _sharedInstallLayout = pending;
    return pending;
  }

  Future<String> stageRuntimePlan({
    required List<BuiltInProxyNodePlan> currentPlans,
    required List<BuiltInProxyNodePlan> nextPlans,
  }) async {
    if (_stagedState != null) {
      return '$typeLabel runtime plan stage is already active.';
    }

    if (currentPlans.isEmpty && nextPlans.isEmpty) {
      // Nothing to stage for this node type. Resolving the shared install
      // layout would need the bundled binary and device ABI info, so a profile
      // that never mentions this runtime must not depend on either.
      _stagedState = const LocalNodeStageState(
        mutations: [],
        removedPlans: [],
      );
      return '';
    }

    final sharedLayout = await resolveSharedInstallLayout();
    await Directory(sharedLayout.runtimeRootPath).create(recursive: true);
    await Directory(sharedLayout.nodesDirectoryPath).create(recursive: true);
    final nextIds = nextPlans.map((plan) => plan.nodeId).toSet();
    final mutations = <LocalNodeMutation<TNodeLayout>>[];

    try {
      for (final plan in nextPlans) {
        final layout = resolveNodeLayout(sharedLayout, plan.nodeId);
        final config = readConfigArtifact(plan);
        final extraArtifacts = readAdditionalArtifacts(plan);
        final configFile = File(layout.configPath);
        final previousConfig =
            configFile.existsSync() ? await configFile.readAsString() : null;

        final previousArtifacts = <String, String?>{};
        var artifactsChanged = false;
        for (final entry in extraArtifacts.entries) {
          final file = File(_artifactPath(layout, entry.key));
          final previous =
              file.existsSync() ? await file.readAsString() : null;
          previousArtifacts[entry.key] = previous;
          if (previous != entry.value) artifactsChanged = true;
        }
        if (previousConfig == config && !artifactsChanged) continue;

        mutations.add(
          LocalNodeMutation<TNodeLayout>(
            plan: plan,
            layout: layout,
            previousConfig: previousConfig,
            previousArtifacts: previousArtifacts,
          ),
        );
        await Directory(layout.workingDirectoryPath).create(recursive: true);
        // Every artifact of one node is staged together so a mid-write failure
        // rolls the whole node back rather than leaving a mixed set on disk.
        await configFile.writeAsString(config, flush: true);
        for (final entry in extraArtifacts.entries) {
          final file = File(_artifactPath(layout, entry.key));
          await file.parent.create(recursive: true);
          await file.writeAsString(entry.value, flush: true);
        }
      }
    } catch (error) {
      return rollbackStageFailure(
        mutations: mutations,
        failureMessage: '$typeLabel runtime plan staging failed: $error',
      );
    }

    _stagedState = LocalNodeStageState<TNodeLayout>(
      mutations: mutations,
      removedPlans: currentPlans
          .where((plan) => !nextIds.contains(plan.nodeId))
          .toList(growable: false),
    );
    return '';
  }

  Future<String> rollbackStagedRuntimePlan() async {
    final stagedState = _stagedState;
    if (stagedState == null) return '';
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
    if (stagedState == null) return;
    _stagedState = null;
    if (stagedState.mutations.isEmpty && stagedState.removedPlans.isEmpty) {
      return;
    }
    try {
      final sharedLayout = await resolveSharedInstallLayout();
      await Future.wait([
        for (final removedPlan in stagedState.removedPlans)
          deleteDirectoryIfExists(
            Directory(
              resolveNodeLayout(sharedLayout, removedPlan.nodeId)
                  .workingDirectoryPath,
            ),
          ),
        for (final mutation in stagedState.mutations)
          commitNode(mutation.plan, sharedLayout, mutation.layout),
      ]);
    } catch (error) {
      commonPrint.log(
        '$typeLabel runtime plan committed, but stale node cleanup failed: '
        '$error',
      );
    }
  }

  Future<List<Map<String, dynamic>>> buildRuntimeNodes(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    if (plans.isEmpty) return const [];
    final sharedLayout = await resolveSharedInstallLayout();
    return Future.wait([
      for (final plan in plans)
        _buildRuntimeNode(sharedLayout: sharedLayout, plan: plan),
    ]).then(
      (nodes) =>
          nodes.whereType<Map<String, dynamic>>().toList(growable: false),
    );
  }

  Future<void> persistColdStart(List<BuiltInProxyNodePlan> plans) async {
    await saveRuntimeNodes(await buildRuntimeNodes(plans));
  }

  Future<void> saveRuntimeNodes(List<Map<String, dynamic>> nodes) async {
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
      return;
    }
    await runtime.saveColdStartNodes(
      json.encode(<String, dynamic>{'nodes': nodes}),
    );
  }

  @protected
  TNodeLayout resolveNodeLayout(TSharedLayout sharedLayout, String nodeId);

  @protected
  String readConfigArtifact(BuiltInProxyNodePlan plan);

  /// Extra artifacts a node needs next to its config, keyed by the path
  /// relative to the node working directory.
  ///
  /// Controllers that only stage a config file keep the default empty map and
  /// behave exactly as before.
  @protected
  Map<String, String> readAdditionalArtifacts(BuiltInProxyNodePlan plan) =>
      const {};

  /// Runs after the runtime plan commits, once the node is known to be the
  /// active one. Used to drop state the previous plan still needed.
  @protected
  Future<void> commitNode(
    BuiltInProxyNodePlan plan,
    TSharedLayout sharedLayout,
    TNodeLayout layout,
  ) async {}

  String _artifactPath(TNodeLayout layout, String relativePath) =>
      '${layout.workingDirectoryPath}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}';

  @protected
  Future<LocalNodeLaunchExtras> buildLaunchExtras(
    BuiltInProxyNodePlan plan,
    TSharedLayout sharedLayout,
    TNodeLayout layout,
  ) async =>
      const LocalNodeLaunchExtras();

  @protected
  Future<String> rollbackStageFailure({
    required List<LocalNodeMutation<TNodeLayout>> mutations,
    required String failureMessage,
  }) async {
    Object? rollbackError;
    for (final mutation in mutations.reversed) {
      try {
        final configFile = File(mutation.layout.configPath);
        if (mutation.previousConfig == null) {
          await deleteFileWithRetry(configFile);
          await deleteDirectoryIfExists(
            Directory(mutation.layout.workingDirectoryPath),
          );
          continue;
        }
        await configFile.writeAsString(mutation.previousConfig!, flush: true);
        // Restore the extra artifacts to the exact state the previously
        // committed plan left behind, including files that did not exist.
        for (final entry in mutation.previousArtifacts.entries) {
          final file = File(_artifactPath(mutation.layout, entry.key));
          if (entry.value == null) {
            await deleteFileWithRetry(file);
            continue;
          }
          await file.parent.create(recursive: true);
          await file.writeAsString(entry.value!, flush: true);
        }
      } catch (error) {
        rollbackError ??= error;
      }
    }
    if (rollbackError == null) return failureMessage;
    commonPrint.log('$failureMessage Rollback failed: $rollbackError');
    return '$failureMessage Rollback failed: $rollbackError';
  }

  @protected
  Future<void> deleteFileWithRetry(File file) async {
    if (!file.existsSync()) return;
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await file.delete();
        return;
      } catch (_) {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  @protected
  Future<void> deleteDirectoryIfExists(Directory directory) async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  }

  Future<Map<String, dynamic>?> _buildRuntimeNode({
    required TSharedLayout sharedLayout,
    required BuiltInProxyNodePlan plan,
  }) async {
    final layout = resolveNodeLayout(sharedLayout, plan.nodeId);
    final extras = await buildLaunchExtras(plan, sharedLayout, layout);
    if (!extras.includeNode) return null;
    final extraArtifacts = readAdditionalArtifacts(plan);
    final revisionSource = json.encode(<String, dynamic>{
      'type': plan.type.label,
      'config': readConfigArtifact(plan),
      'connectivityCheck': plan.connectivityCheck.toJson(),
      'extra': extras.fields,
      // Only emitted for multi-artifact nodes, so single-artifact revisions
      // stay byte-identical to what earlier releases produced.
      if (extraArtifacts.isNotEmpty) 'artifacts': extraArtifacts,
    });
    return <String, dynamic>{
      'nodeId': plan.nodeId,
      'type': plan.type.label,
      'name': plan.name,
      'host': plan.listenHost,
      'port': plan.listenPort,
      'executablePath': sharedLayout.executablePath,
      'workingDirectory': layout.workingDirectoryPath,
      'connectivityCheck': plan.connectivityCheck.toJson(),
      'revision': sha256.convert(utf8.encode(revisionSource)).toString(),
      ...extras.fields,
    };
  }
}
