import 'package:flclashx/product/android/android_runtime_node_bridge.dart';

import 'built_in_proxy_types.dart';
import 'byedpi_node_controller.dart';
import 'naiveproxy_node_controller.dart';
import 'olcrtc_node_controller.dart';

class BuiltInProxyRuntimePlanStartResult {
  const BuiltInProxyRuntimePlanStartResult({
    required this.isSuccess,
    this.state,
  });

  final bool isSuccess;
  final RuntimeNodePlanState? state;
}

abstract interface class BuiltInProxySupervisor {
  bool get hasCommittedRuntimePlan;

  Future<void> prepareForRestart();

  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<String> rollbackStagedRuntimePlan();

  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<BuiltInProxyRuntimePlanStartResult> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  });

  Future<bool> start({bool stopAllOnFailure = true});

  Future<void> stop();

  Future<void> persistColdStart();
}

class DefaultBuiltInProxySupervisor implements BuiltInProxySupervisor {
  DefaultBuiltInProxySupervisor({
    NaiveProxyNodeController? naiveProxy,
    ByedpiNodeController? byedpi,
    OlcRtcNodeController? olcRtc,
    RuntimeNodePlatformBridge? runtime,
  })  : naiveProxy = naiveProxy ?? NaiveProxyNodeController(),
        byedpi = byedpi ?? ByedpiNodeController(),
        olcRtc = olcRtc ?? OlcRtcNodeController(),
        runtime = runtime ??
            naiveProxy?.runtime ??
            byedpi?.runtime ??
            olcRtc?.runtime ??
            const AndroidRuntimeNodeBridge();

  final NaiveProxyNodeController naiveProxy;
  final ByedpiNodeController byedpi;
  final OlcRtcNodeController olcRtc;
  final RuntimeNodePlatformBridge runtime;

  List<BuiltInProxyNodePlan> _currentPlans = const [];
  int _planGeneration = 0;

  @override
  bool get hasCommittedRuntimePlan => _currentPlans.isNotEmpty;

  List<BuiltInProxyNodePlan> _filter(
    List<BuiltInProxyNodePlan> plans,
    BuiltInProxyType type,
  ) =>
      plans.where((plan) => plan.type == type).toList(growable: false);

  @override
  Future<void> prepareForRestart() async {
    _planGeneration++;
    byedpi.cancelBackgroundSelection();
  }

  @override
  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    _planGeneration++;
    byedpi.cancelBackgroundSelection();
    final naiveMessage = await naiveProxy.stageRuntimePlan(
      currentPlans: _filter(_currentPlans, BuiltInProxyType.naiveproxy),
      nextPlans: _filter(plans, BuiltInProxyType.naiveproxy),
    );
    if (naiveMessage.isNotEmpty) return naiveMessage;

    final byedpiMessage = await byedpi.stageRuntimePlan(
      currentPlans: _filter(_currentPlans, BuiltInProxyType.byedpi),
      nextPlans: _filter(plans, BuiltInProxyType.byedpi),
    );
    if (byedpiMessage.isNotEmpty) {
      final rollback = await naiveProxy.rollbackStagedRuntimePlan();
      return rollback.isEmpty
          ? byedpiMessage
          : '$byedpiMessage Local-node rollback failed: $rollback';
    }

    final olcMessage = await olcRtc.stageRuntimePlan(
      currentPlans: _filter(_currentPlans, BuiltInProxyType.olcrtc),
      nextPlans: _filter(plans, BuiltInProxyType.olcrtc),
    );
    if (olcMessage.isEmpty) return '';
    final rollback = await Future.wait([
      byedpi.rollbackStagedRuntimePlan(),
      naiveProxy.rollbackStagedRuntimePlan(),
    ]);
    final failures = rollback.where((message) => message.isNotEmpty).join(' ');
    return failures.isEmpty
        ? olcMessage
        : '$olcMessage Local-node rollback failed: $failures';
  }

  @override
  Future<String> rollbackStagedRuntimePlan() async {
    final messages = await Future.wait([
      olcRtc.rollbackStagedRuntimePlan(),
      byedpi.rollbackStagedRuntimePlan(),
      naiveProxy.rollbackStagedRuntimePlan(),
    ]);
    final failures = messages.where((message) => message.isNotEmpty).join(' ');
    if (failures.isNotEmpty) return failures;

    final restored = await _applyPlans(_currentPlans);
    return restored.isReady
        ? ''
        : 'Previous runtime-node plan could not be restored: ${restored.message}';
  }

  @override
  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    await Future.wait([
      naiveProxy.commitStagedRuntimePlan(),
      byedpi.commitStagedRuntimePlan(),
      olcRtc.commitStagedRuntimePlan(),
    ]);
    _currentPlans = List<BuiltInProxyNodePlan>.unmodifiable(plans);
    final generation = _planGeneration;
    byedpi.startBackgroundSelection(
      _filter(_currentPlans, BuiltInProxyType.byedpi),
      onSelectionChanged: () => _activateBackgroundSelection(generation),
    );
  }

  @override
  Future<BuiltInProxyRuntimePlanStartResult> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  }) async {
    final state = await _applyPlans(plans);
    return BuiltInProxyRuntimePlanStartResult(
      isSuccess: state.isReady,
      state: state,
    );
  }

  @override
  Future<bool> start({bool stopAllOnFailure = true}) async =>
      (await startRuntimePlan(
        _currentPlans,
        stopAllOnFailure: stopAllOnFailure,
      ))
          .isSuccess;

  @override
  Future<void> stop() async {
    _planGeneration++;
    byedpi.cancelBackgroundSelection();
    await runtime.stopPlan();
  }

  @override
  Future<void> persistColdStart() async {
    final nodes = await _buildRuntimeNodes(_currentPlans);
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
    } else {
      await naiveProxy.saveRuntimeNodes(nodes);
    }
  }

  Future<RuntimeNodePlanState> _applyPlans(
    List<BuiltInProxyNodePlan> plans,
  ) async =>
      runtime.applyPlan(await _buildRuntimeNodes(plans));

  Future<List<Map<String, dynamic>>> _buildRuntimeNodes(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    final groups = await Future.wait([
      naiveProxy.buildRuntimeNodes(
        _filter(plans, BuiltInProxyType.naiveproxy),
      ),
      byedpi.buildRuntimeNodes(
        _filter(plans, BuiltInProxyType.byedpi),
      ),
      olcRtc.buildRuntimeNodes(
        _filter(plans, BuiltInProxyType.olcrtc),
      ),
    ]);
    return [for (final group in groups) ...group];
  }

  Future<bool> _activateBackgroundSelection(int generation) async {
    final nodes = await _buildRuntimeNodes(_currentPlans);
    if (generation != _planGeneration) return false;
    final state = await runtime.applyPlan(nodes);
    if (!state.isReady) return false;
    if (generation != _planGeneration) return false;
    try {
      await naiveProxy.saveRuntimeNodes(nodes);
    } catch (_) {
      // The live runtime has already switched successfully. Cold-start state
      // will be refreshed by the next normal persistence point.
    }
    return true;
  }
}
