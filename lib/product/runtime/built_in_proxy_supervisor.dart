import 'built_in_proxy_types.dart';
import 'naiveproxy_node_controller.dart';
import 'olcrtc_node_controller.dart';

abstract interface class BuiltInProxySupervisor {
  Future<void> applyPendingUpdate();

  Future<void> prepareForRestart();

  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<String> rollbackStagedRuntimePlan();

  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans);

  Future<bool> start();

  Future<void> stop();

  Future<void> persistColdStart();
}

class DefaultBuiltInProxySupervisor implements BuiltInProxySupervisor {
  DefaultBuiltInProxySupervisor({
    NaiveProxyNodeController? naiveProxy,
    OlcRtcNodeController? olcRtc,
  })  : naiveProxy = naiveProxy ?? NaiveProxyNodeController(),
        olcRtc = olcRtc ?? OlcRtcNodeController();

  final NaiveProxyNodeController naiveProxy;
  final OlcRtcNodeController olcRtc;

  List<BuiltInProxyNodePlan> _currentPlans = const [];

  List<BuiltInProxyNodePlan> get _currentNaiveProxyPlans => _currentPlans
      .where((plan) => plan.type == BuiltInProxyType.naiveproxy)
      .toList(growable: false);

  List<BuiltInProxyNodePlan> get _currentOlcRtcPlans => _currentPlans
      .where((plan) => plan.type == BuiltInProxyType.olcrtc)
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

  @override
  Future<void> applyPendingUpdate() async {
    await naiveProxy.applyPendingUpdate();
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

    final olcRtcMessage = await olcRtc.stageRuntimePlan(
      currentPlans: _currentOlcRtcPlans,
      nextPlans: _filterOlcRtcPlans(plans),
    );
    if (olcRtcMessage.isEmpty) {
      return '';
    }

    final rollbackMessage = await naiveProxy.rollbackStagedRuntimePlan();
    if (rollbackMessage.isEmpty) {
      return olcRtcMessage;
    }
    return '$olcRtcMessage Local-node rollback failed: $rollbackMessage';
  }

  @override
  Future<String> rollbackStagedRuntimePlan() async {
    final olcRtcMessage = await olcRtc.rollbackStagedRuntimePlan();
    final naiveProxyMessage = await naiveProxy.rollbackStagedRuntimePlan();
    return [
      if (olcRtcMessage.isNotEmpty) olcRtcMessage,
      if (naiveProxyMessage.isNotEmpty) naiveProxyMessage,
    ].join(' ');
  }

  @override
  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    await naiveProxy.commitStagedRuntimePlan();
    await olcRtc.commitStagedRuntimePlan();
    _currentPlans = List<BuiltInProxyNodePlan>.unmodifiable(plans);
  }

  @override
  Future<bool> start() async {
    final naiveProxyStarted = await naiveProxy.startNodes(
      _currentNaiveProxyPlans,
    );
    if (!naiveProxyStarted) {
      return false;
    }
    final olcRtcStarted = await olcRtc.startNodes(_currentOlcRtcPlans);
    if (olcRtcStarted) {
      return true;
    }
    await naiveProxy.stopNodes(_currentNaiveProxyPlans);
    return false;
  }

  @override
  Future<void> stop() async {
    Object? error;
    StackTrace? stackTrace;
    try {
      await olcRtc.stopNodes(_currentOlcRtcPlans);
    } catch (e, s) {
      error ??= e;
      stackTrace ??= s;
    }
    try {
      await naiveProxy.stopNodes(_currentNaiveProxyPlans);
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
      ...await olcRtc.buildColdStartNodes(_currentOlcRtcPlans),
    ];
    await naiveProxy.saveColdStartNodes(nodes);
  }
}
