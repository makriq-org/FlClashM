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
  });

  final BuiltInProxyNodePlan plan;
  final TNodeLayout layout;
  final String? previousConfig;
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
    final nextIds = nextPlans.map((plan) => plan.nodeId).toSet();
    final mutations = <LocalNodeMutation<TNodeLayout>>[];

    try {
      for (final plan in nextPlans) {
        final layout = resolveNodeLayout(sharedLayout, plan.nodeId);
        final config = readConfigArtifact(plan);
        final configFile = File(layout.configPath);
        final previousConfig =
            configFile.existsSync() ? await configFile.readAsString() : null;
        if (previousConfig == config) continue;

        mutations.add(
          LocalNodeMutation<TNodeLayout>(
            plan: plan,
            layout: layout,
            previousConfig: previousConfig,
          ),
        );
        await Directory(layout.workingDirectoryPath).create(recursive: true);
        await configFile.writeAsString(config, flush: true);
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
    try {
      final sharedLayout = await binary.resolveSharedInstallLayout();
      await Future.wait([
        for (final removedPlan in stagedState.removedPlans)
          deleteDirectoryIfExists(
            Directory(
              resolveNodeLayout(sharedLayout, removedPlan.nodeId)
                  .workingDirectoryPath,
            ),
          ),
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
    final sharedLayout = await binary.resolveSharedInstallLayout();
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
        } else {
          await configFile.writeAsString(mutation.previousConfig!, flush: true);
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
    final revisionSource = json.encode(<String, dynamic>{
      'type': plan.type.label,
      'config': readConfigArtifact(plan),
      'connectivityCheck': plan.connectivityCheck.toJson(),
      'extra': extras.fields,
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
