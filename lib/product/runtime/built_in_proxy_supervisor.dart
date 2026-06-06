import 'built_in_proxy_types.dart';
import 'byedpi_node_controller.dart';
import 'naiveproxy_node_controller.dart';
import 'olcrtc_node_controller.dart';

abstract interface class BuiltInProxySupervisor {
  Future<void> applyPendingUpdate();

  Future<void> prepareForRestart();

  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<String> rollbackStagedRuntimePlan();

  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<bool> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  });

  Future<bool> start();

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
  Future<void> applyPendingUpdate() async {
    await naiveProxy.applyPendingUpdate();
    await byedpi.applyPendingUpdate();
    await olcRtc.applyPendingUpdate();
  }

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
  Future<bool> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  }) async {
    try {
      final started = await Future.wait([
        naiveProxy.startNodes(_filterNaiveProxyPlans(plans)),
        byedpi.startNodes(_filterByedpiPlans(plans)),
        olcRtc.startNodes(_filterOlcRtcPlans(plans)),
      ]);
      if (started.every((value) => value)) {
        return true;
      }
    } catch (e, stackTrace) {
      if (stopAllOnFailure) {
        await _stopRuntimePlan(plans);
      }
      Error.throwWithStackTrace(e, stackTrace);
    }

    if (stopAllOnFailure) {
      await _stopRuntimePlan(plans);
    }
    return false;
  }

  @override
  Future<bool> start() => startRuntimePlan(_currentPlans);

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
