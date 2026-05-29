import 'built_in_proxy_types.dart';
import 'naiveproxy_node_controller.dart';

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
  }) : naiveProxy = naiveProxy ?? NaiveProxyNodeController();

  final NaiveProxyNodeController naiveProxy;

  List<BuiltInProxyNodePlan> _currentPlans = const [];

  List<BuiltInProxyNodePlan> get _currentNaiveProxyPlans => _currentPlans
      .where((plan) => plan.type == BuiltInProxyType.naiveproxy)
      .toList(growable: false);

  List<BuiltInProxyNodePlan> _filterNaiveProxyPlans(
    List<BuiltInProxyNodePlan> plans,
  ) =>
      plans
          .where((plan) => plan.type == BuiltInProxyType.naiveproxy)
          .toList(growable: false);

  @override
  Future<void> applyPendingUpdate() => naiveProxy.applyPendingUpdate();

  @override
  Future<void> prepareForRestart() => stop();

  @override
  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans) =>
      naiveProxy.stageRuntimePlan(
        currentPlans: _currentNaiveProxyPlans,
        nextPlans: _filterNaiveProxyPlans(plans),
      );

  @override
  Future<String> rollbackStagedRuntimePlan() =>
      naiveProxy.rollbackStagedRuntimePlan();

  @override
  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    await naiveProxy.commitStagedRuntimePlan();
    _currentPlans = List<BuiltInProxyNodePlan>.unmodifiable(plans);
  }

  @override
  Future<bool> start() => naiveProxy.startNodes(_currentNaiveProxyPlans);

  @override
  Future<void> stop() => naiveProxy.stopNodes(_currentNaiveProxyPlans);

  @override
  Future<void> persistColdStart() =>
      naiveProxy.persistColdStart(_currentNaiveProxyPlans);
}
