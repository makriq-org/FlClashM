import 'built_in_proxy_types.dart';
import 'byedpi_node_controller.dart';
import 'naiveproxy_node_controller.dart';
import 'olcrtc_node_controller.dart';

class BuiltInProxyRuntimePlanStartResult {
  const BuiltInProxyRuntimePlanStartResult({
    required this.isSuccess,
    this.startedPlans = const [],
  });

  final bool isSuccess;
  final List<BuiltInProxyNodePlan> startedPlans;
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

  Future<void> stopRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<bool> start({bool stopAllOnFailure = true});

  Future<void> stop();

  Future<void> persistColdStart();
}

class DefaultBuiltInProxySupervisor implements BuiltInProxySupervisor {
  DefaultBuiltInProxySupervisor({
    NaiveProxyNodeController? naiveProxy,
    ByedpiNodeController? byedpi,
    OlcRtcNodeController? olcRtc,
  })  : naiveProxy = naiveProxy ?? NaiveProxyNodeController(),
        byedpi = byedpi ?? ByedpiNodeController(),
        olcRtc = olcRtc ?? OlcRtcNodeController();

  final NaiveProxyNodeController naiveProxy;
  final ByedpiNodeController byedpi;
  final OlcRtcNodeController olcRtc;

  List<BuiltInProxyNodePlan> _currentPlans = const [];

  @override
  bool get hasCommittedRuntimePlan => _currentPlans.isNotEmpty;

  List<BuiltInProxyNodePlan> get _currentNaiveProxyPlans => _currentPlans
      .where((plan) => plan.type == BuiltInProxyType.naiveproxy)
      .toList(growable: false);

  List<BuiltInProxyNodePlan> get _currentOlcRtcPlans => _currentPlans
      .where((plan) => plan.type == BuiltInProxyType.olcrtc)
      .toList(growable: false);

  List<BuiltInProxyNodePlan> get _currentByedpiPlans => _currentPlans
      .where((plan) => plan.type == BuiltInProxyType.byedpi)
      .toList(growable: false);

  List<BuiltInProxyNodePlan> _filterNaiveProxyPlans(
    List<BuiltInProxyNodePlan> plans,
  ) =>
      plans
          .where((plan) => plan.type == BuiltInProxyType.naiveproxy)
          .toList(growable: false);

  List<BuiltInProxyNodePlan> _filterOlcRtcPlans(
    List<BuiltInProxyNodePlan> plans,
  ) =>
      plans
          .where((plan) => plan.type == BuiltInProxyType.olcrtc)
          .toList(growable: false);

  List<BuiltInProxyNodePlan> _filterByedpiPlans(
    List<BuiltInProxyNodePlan> plans,
  ) =>
      plans
          .where((plan) => plan.type == BuiltInProxyType.byedpi)
          .toList(growable: false);

  @override
  Future<void> prepareForRestart() => stop();

  @override
  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    final naiveProxyMessage = await naiveProxy.stageRuntimePlan(
      currentPlans: _currentNaiveProxyPlans,
      nextPlans: _filterNaiveProxyPlans(plans),
    );
    if (naiveProxyMessage.isNotEmpty) {
      return naiveProxyMessage;
    }

    final byedpiMessage = await byedpi.stageRuntimePlan(
      currentPlans: _currentByedpiPlans,
      nextPlans: _filterByedpiPlans(plans),
    );
    if (byedpiMessage.isNotEmpty) {
      final rollbackMessage = await naiveProxy.rollbackStagedRuntimePlan();
      if (rollbackMessage.isEmpty) {
        return byedpiMessage;
      }
      return '$byedpiMessage Local-node rollback failed: $rollbackMessage';
    }

    final olcRtcMessage = await olcRtc.stageRuntimePlan(
      currentPlans: _currentOlcRtcPlans,
      nextPlans: _filterOlcRtcPlans(plans),
    );
    if (olcRtcMessage.isEmpty) {
      return '';
    }

    final byedpiRollbackMessage = await byedpi.rollbackStagedRuntimePlan();
    final naiveProxyRollbackMessage =
        await naiveProxy.rollbackStagedRuntimePlan();
    final rollbackMessage = [
      if (byedpiRollbackMessage.isNotEmpty) byedpiRollbackMessage,
      if (naiveProxyRollbackMessage.isNotEmpty) naiveProxyRollbackMessage,
    ].join(' ');
    if (rollbackMessage.isEmpty) {
      return olcRtcMessage;
    }
    return '$olcRtcMessage Local-node rollback failed: $rollbackMessage';
  }

  @override
  Future<String> rollbackStagedRuntimePlan() async {
    final olcRtcMessage = await olcRtc.rollbackStagedRuntimePlan();
    final byedpiMessage = await byedpi.rollbackStagedRuntimePlan();
    final naiveProxyMessage = await naiveProxy.rollbackStagedRuntimePlan();
    return [
      if (olcRtcMessage.isNotEmpty) olcRtcMessage,
      if (byedpiMessage.isNotEmpty) byedpiMessage,
      if (naiveProxyMessage.isNotEmpty) naiveProxyMessage,
    ].join(' ');
  }

  @override
  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    await naiveProxy.commitStagedRuntimePlan();
    await byedpi.commitStagedRuntimePlan();
    await olcRtc.commitStagedRuntimePlan();
    _currentPlans = List<BuiltInProxyNodePlan>.unmodifiable(plans);
  }

  @override
  Future<BuiltInProxyRuntimePlanStartResult> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  }) async {
    final startedPlans = <BuiltInProxyNodePlan>[];
    final naiveProxyPlans = _filterNaiveProxyPlans(plans);
    final byedpiPlans = _filterByedpiPlans(plans);
    final olcRtcPlans = _filterOlcRtcPlans(plans);
    try {
      final naiveProxyResult = await _startControllerPlans(
        plans: naiveProxyPlans,
        startNodes: naiveProxy.startNodes,
        readNodeStartTime: naiveProxy.runtime.readNodeStartTime,
      );
      if (!naiveProxyResult.isSuccess) {
        return naiveProxyResult;
      }
      startedPlans.addAll(naiveProxyResult.startedPlans);

      final byedpiResult = await _startControllerPlans(
        plans: byedpiPlans,
        startNodes: byedpi.startNodes,
        readNodeStartTime: byedpi.runtime.readNodeStartTime,
      );
      if (!byedpiResult.isSuccess) {
        if (stopAllOnFailure) {
          await _stopRuntimePlan(startedPlans);
        }
        return BuiltInProxyRuntimePlanStartResult(
          isSuccess: false,
          startedPlans: List<BuiltInProxyNodePlan>.unmodifiable(startedPlans),
        );
      }
      startedPlans.addAll(byedpiResult.startedPlans);

      final olcRtcResult = await _startControllerPlans(
        plans: olcRtcPlans,
        startNodes: olcRtc.startNodes,
        readNodeStartTime: olcRtc.runtime.readNodeStartTime,
      );
      if (!olcRtcResult.isSuccess) {
        if (stopAllOnFailure) {
          await _stopRuntimePlan(startedPlans);
        }
        return BuiltInProxyRuntimePlanStartResult(
          isSuccess: false,
          startedPlans: List<BuiltInProxyNodePlan>.unmodifiable(startedPlans),
        );
      }
      startedPlans.addAll(olcRtcResult.startedPlans);
      return BuiltInProxyRuntimePlanStartResult(
        isSuccess: true,
        startedPlans: List<BuiltInProxyNodePlan>.unmodifiable(startedPlans),
      );
    } catch (e, stackTrace) {
      if (stopAllOnFailure) {
        await _stopRuntimePlan(startedPlans);
      }
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  @override
  Future<void> stopRuntimePlan(List<BuiltInProxyNodePlan> plans) =>
      _stopRuntimePlan(plans);

  @override
  Future<bool> start({bool stopAllOnFailure = true}) async {
    final result = await startRuntimePlan(
      _currentPlans,
      stopAllOnFailure: stopAllOnFailure,
    );
    return result.isSuccess;
  }

  @override
  Future<void> stop() => _stopRuntimePlan(_currentPlans);

  Future<void> _stopRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    Object? error;
    StackTrace? stackTrace;
    try {
      await olcRtc.stopNodes(_filterOlcRtcPlans(plans));
    } catch (e, s) {
      error ??= e;
      stackTrace ??= s;
    }
    try {
      await byedpi.stopNodes(_filterByedpiPlans(plans));
    } catch (e, s) {
      error ??= e;
      stackTrace ??= s;
    }
    try {
      await naiveProxy.stopNodes(_filterNaiveProxyPlans(plans));
    } catch (e, s) {
      error ??= e;
      stackTrace ??= s;
    }
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  Future<BuiltInProxyRuntimePlanStartResult> _startControllerPlans({
    required List<BuiltInProxyNodePlan> plans,
    required Future<bool> Function(List<BuiltInProxyNodePlan> plans) startNodes,
    required Future<DateTime?> Function({required String nodeId})
        readNodeStartTime,
  }) async {
    if (plans.isEmpty) {
      return const BuiltInProxyRuntimePlanStartResult(isSuccess: true);
    }

    final runningNodeIds = <String>{};
    for (final plan in plans) {
      if (await readNodeStartTime(nodeId: plan.nodeId) != null) {
        runningNodeIds.add(plan.nodeId);
      }
    }

    final started = await startNodes(plans);
    if (!started) {
      return const BuiltInProxyRuntimePlanStartResult(isSuccess: false);
    }

    return BuiltInProxyRuntimePlanStartResult(
      isSuccess: true,
      startedPlans: List<BuiltInProxyNodePlan>.unmodifiable(
        plans
            .where((plan) => !runningNodeIds.contains(plan.nodeId))
            .toList(growable: false),
      ),
    );
  }

  @override
  Future<void> persistColdStart() async {
    final nodes = [
      ...await naiveProxy.buildColdStartNodes(_currentNaiveProxyPlans),
      ...await byedpi.buildColdStartNodes(_currentByedpiPlans),
      ...await olcRtc.buildColdStartNodes(_currentOlcRtcPlans),
    ];
    await naiveProxy.saveColdStartNodes(nodes);
  }
}
