import 'dart:async';

import 'package:flclashx/product/android/android_runtime_node_bridge.dart';

import 'built_in_proxy_types.dart';
import 'byedpi_node_controller.dart';
import 'local_node_controller.dart';
import 'naiveproxy_node_controller.dart';
import 'olcrtc_node_controller.dart';
import 'runtime_health_probe.dart';
import 'stormdns_node_controller.dart';

final _reserveMonotonicClock = Stopwatch()..start();

/// Any local-node controller, regardless of its layout types. Dart generics are
/// covariant, so every concrete controller is assignable to this.
typedef AnyLocalNodeController
    = LocalNodeController<LocalNodeSharedInstallLayout, LocalNodeLayout>;

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

  Future<void> notifyProxySelected(String groupName, String proxyName);

  Future<void> pauseAutoActivation();

  Future<void> stop();

  Future<void> persistColdStart();
}

class DefaultBuiltInProxySupervisor implements BuiltInProxySupervisor {
  DefaultBuiltInProxySupervisor({
    NaiveProxyNodeController? naiveProxy,
    ByedpiNodeController? byedpi,
    OlcRtcNodeController? olcRtc,
    StormDnsNodeController? stormDns,
    RuntimeNodePlatformBridge? runtime,
    this.healthProbe,
    Duration Function()? monotonicNow,
    Future<void> Function(Duration)? delay,
  })  : naiveProxy = naiveProxy ?? NaiveProxyNodeController(),
        byedpi = byedpi ?? ByedpiNodeController(),
        olcRtc = olcRtc ?? OlcRtcNodeController(),
        stormDns = stormDns ?? StormDnsNodeController(),
        runtime = runtime ??
            naiveProxy?.runtime ??
            byedpi?.runtime ??
            olcRtc?.runtime ??
            stormDns?.runtime ??
            const AndroidRuntimeNodeBridge(),
        monotonicNow = monotonicNow ?? _readReserveMonotonicClock,
        delay = delay ?? Future<void>.delayed;

  final NaiveProxyNodeController naiveProxy;
  final ByedpiNodeController byedpi;
  final OlcRtcNodeController olcRtc;
  final StormDnsNodeController stormDns;
  final RuntimeNodePlatformBridge runtime;
  final RuntimeHealthProbe? healthProbe;
  final Duration Function() monotonicNow;
  final Future<void> Function(Duration) delay;

  List<BuiltInProxyNodePlan> _currentPlans = const [];
  Set<String> _awakeReserveNodeIds = <String>{};
  Set<String> _rollbackAwakeReserveNodeIds = <String>{};
  final Map<String, _ReserveNodeState> _reserveStates = {};
  int _planGeneration = 0;
  int _watchdogGeneration = 0;
  Future<void>? _watchdogWorker;
  Completer<void>? _watchdogCancellation;
  Future<void> _runtimeMutation = Future<void>.value();
  bool _autoActivationRunning = false;

  @override
  bool get hasCommittedRuntimePlan => _currentPlans.isNotEmpty;

  List<BuiltInProxyNodePlan> _filter(
    List<BuiltInProxyNodePlan> plans,
    BuiltInProxyType type,
  ) =>
      plans.where((plan) => plan.type == type).toList(growable: false);

  @override
  Future<void> prepareForRestart() {
    _planGeneration++;
    return _serializeRuntimeMutation(() async {
      await _pauseAutoActivationLocked(cancelBackgroundSelection: true);
    });
  }

  /// Local-node controllers in staging order. Each entry owns exactly one node
  /// type; adding a runtime node means adding one entry here.
  List<({BuiltInProxyType type, AnyLocalNodeController controller})>
      get _controllers => [
            (type: BuiltInProxyType.naiveproxy, controller: naiveProxy),
            (type: BuiltInProxyType.byedpi, controller: byedpi),
            (type: BuiltInProxyType.olcrtc, controller: olcRtc),
            (type: BuiltInProxyType.stormdns, controller: stormDns),
          ];

  @override
  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans) {
    _planGeneration++;
    return _serializeRuntimeMutation(() async {
      await _cancelWatchdog();
      await byedpi.cancelBackgroundSelection();
      _rollbackAwakeReserveNodeIds = Set<String>.from(_awakeReserveNodeIds);

      final staged = <AnyLocalNodeController>[];
      for (final entry in _controllers) {
        final message = await entry.controller.stageRuntimePlan(
          currentPlans: _filter(_currentPlans, entry.type),
          nextPlans: _filter(plans, entry.type),
        );
        if (message.isEmpty) {
          staged.add(entry.controller);
          continue;
        }
        // Undo the controllers that already staged, newest first, so disk
        // state matches the last committed plan again.
        final rollback = await Future.wait([
          for (final controller in staged.reversed)
            controller.rollbackStagedRuntimePlan(),
        ]);
        final failures =
            rollback.where((failure) => failure.isNotEmpty).join(' ');
        _startWatchdog(_planGeneration);
        return failures.isEmpty
            ? message
            : '$message Local-node rollback failed: $failures';
      }

      _awakeReserveNodeIds.clear();
      _reserveStates.clear();
      return '';
    });
  }

  @override
  Future<String> rollbackStagedRuntimePlan() =>
      _serializeRuntimeMutation(() async {
        final messages = await Future.wait([
          for (final entry in _controllers.reversed)
            entry.controller.rollbackStagedRuntimePlan(),
        ]);
        final failures =
            messages.where((message) => message.isNotEmpty).join(' ');
        if (failures.isNotEmpty) return failures;

        _awakeReserveNodeIds = Set<String>.from(_rollbackAwakeReserveNodeIds);
        final restored = await _applyPlans(_currentPlans);
        if (!restored.isReady) {
          return 'Previous runtime-node plan could not be restored: ${restored.message}';
        }
        _startWatchdog(_planGeneration);
        return '';
      });

  @override
  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans) =>
      _serializeRuntimeMutation(() async {
        await Future.wait([
          for (final entry in _controllers)
            entry.controller.commitStagedRuntimePlan(),
        ]);
        _currentPlans = List<BuiltInProxyNodePlan>.unmodifiable(plans);
        final generation = _planGeneration;
        byedpi.startBackgroundSelection(
          _filter(_currentPlans, BuiltInProxyType.byedpi),
          onSelectionChanged: () => _activateBackgroundSelection(generation),
        );
        _startWatchdog(generation);
      });

  @override
  Future<BuiltInProxyRuntimePlanStartResult> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  }) =>
      _serializeRuntimeMutation(() async {
        final state = await _applyPlans(plans);
        return BuiltInProxyRuntimePlanStartResult(
          isSuccess: state.isReady,
          state: state,
        );
      });

  @override
  Future<bool> start({bool stopAllOnFailure = true}) =>
      _serializeRuntimeMutation(() async {
        final state = await _applyPlans(_currentPlans);
        if (!state.isReady) return false;
        _autoActivationRunning = true;
        _startWatchdog(_planGeneration);
        return true;
      });

  @override
  Future<void> notifyProxySelected(String groupName, String proxyName) async {
    final matches = _currentPlans.where(
      (candidate) =>
          candidate.name == proxyName &&
          _isReserve(candidate) &&
          !_awakeReserveNodeIds.contains(candidate.nodeId),
    );
    if (matches.isEmpty) return;
    final plan = matches.first;
    final state = _reserveStates[plan.nodeId];
    if (state == null) return;
    await _wakeNode(plan, state, _planGeneration);
  }

  @override
  Future<void> pauseAutoActivation() {
    _planGeneration++;
    return _serializeRuntimeMutation(_pauseAutoActivationLocked);
  }

  @override
  Future<void> stop() {
    _planGeneration++;
    return _serializeRuntimeMutation(() async {
      _autoActivationRunning = false;
      await _cancelWatchdog();
      await byedpi.cancelBackgroundSelection();
      _awakeReserveNodeIds.clear();
      _reserveStates.clear();
      await runtime.stopPlan();
    });
  }

  @override
  Future<void> persistColdStart() => _serializeRuntimeMutation(() async {
        final nodes = await _buildRuntimeNodes(_currentPlans);
        await _saveRuntimeNodes(nodes);
      });

  Future<void> _pauseAutoActivationLocked({
    bool cancelBackgroundSelection = false,
  }) async {
    _autoActivationRunning = false;
    await _cancelWatchdog();
    if (cancelBackgroundSelection) {
      await byedpi.cancelBackgroundSelection();
    }
    _awakeReserveNodeIds.clear();
    _reserveStates.clear();
    final nodes = await _buildRuntimeNodes(_currentPlans);
    final state = await runtime.applyPlan(nodes);
    try {
      await _saveRuntimeNodes(nodes);
    } catch (_) {}
    if (!state.isReady) {
      throw StateError(state.message);
    }
  }

  Future<RuntimeNodePlanState> _applyPlans(
    List<BuiltInProxyNodePlan> plans,
  ) async =>
      runtime.applyPlan(await _buildRuntimeNodes(plans));

  Future<List<Map<String, dynamic>>> _buildRuntimeNodes(
    List<BuiltInProxyNodePlan> plans,
  ) async {
    final activePlans = plans
        .where(
          (plan) =>
              !_isReserve(plan) || _awakeReserveNodeIds.contains(plan.nodeId),
        )
        .toList(growable: false);
    final groups = await Future.wait([
      for (final entry in _controllers)
        entry.controller.buildRuntimeNodes(_filter(activePlans, entry.type)),
    ]);
    return [for (final group in groups) ...group];
  }

  Future<void> _saveRuntimeNodes(List<Map<String, dynamic>> nodes) async {
    if (nodes.isEmpty) {
      await runtime.clearColdStartNodes();
    } else {
      await naiveProxy.saveRuntimeNodes(nodes);
    }
  }

  Future<bool> _activateBackgroundSelection(
    int generation,
  ) =>
      _serializeRuntimeMutation(() async {
        final nodes = await _buildRuntimeNodes(_currentPlans);
        if (generation != _planGeneration) return false;
        final state = await runtime.applyPlan(nodes);
        if (generation != _planGeneration || !state.isReady) return false;
        try {
          await _saveRuntimeNodes(nodes);
        } catch (_) {
          // The live runtime has already switched successfully. Cold-start state
          // will be refreshed by the next normal persistence point.
        }
        return generation == _planGeneration;
      });

  void _startWatchdog(int planGeneration) {
    final reservePlans = _reservePlans;
    _reserveStates.clear();
    if (!_autoActivationRunning || reservePlans.isEmpty) return;
    final now = monotonicNow();
    for (final plan in reservePlans) {
      final activation = plan.activation!;
      _reserveStates[plan.nodeId] = _ReserveNodeState(
        nextCheck: now + activation.wakeInterval,
      );
    }
    if (healthProbe == null) return;
    final watchdogGeneration = ++_watchdogGeneration;
    final cancellation = Completer<void>();
    _watchdogCancellation = cancellation;
    final previousWorker = _watchdogWorker;
    final worker = () async {
      await previousWorker;
      if (!_watchdogIsCurrent(watchdogGeneration, planGeneration)) return;
      await _runWatchdog(
        watchdogGeneration: watchdogGeneration,
        planGeneration: planGeneration,
        cancellation: cancellation.future,
      );
    }();
    _watchdogWorker = worker;
    unawaited(worker);
  }

  Future<void> _cancelWatchdog() async {
    _watchdogGeneration++;
    final cancellation = _watchdogCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _watchdogCancellation = null;
    final worker = _watchdogWorker;
    await worker;
    if (identical(_watchdogWorker, worker)) _watchdogWorker = null;
  }

  Future<void> _runWatchdog({
    required int watchdogGeneration,
    required int planGeneration,
    required Future<void> cancellation,
  }) async {
    while (_watchdogIsCurrent(watchdogGeneration, planGeneration)) {
      final states = _reserveStates.values.toList(growable: false);
      if (states.isEmpty) return;
      final now = monotonicNow();
      var wait = states
          .map((state) => state.nextCheck - now)
          .reduce((left, right) => left < right ? left : right);
      if (wait.isNegative) wait = Duration.zero;
      await Future.any<void>([delay(wait), cancellation]);
      if (!_watchdogIsCurrent(watchdogGeneration, planGeneration)) return;
      final roundNow = monotonicNow();
      for (final plan in _reservePlans) {
        final state = _reserveStates[plan.nodeId];
        if (state == null || roundNow < state.nextCheck) continue;
        final activation = plan.activation!;
        state.nextCheck = roundNow + activation.wakeInterval;
        if (_awakeReserveNodeIds.contains(plan.nodeId)) {
          await _checkSleep(plan, state, planGeneration);
        } else {
          await _checkWake(plan, state, planGeneration);
        }
        if (!_watchdogIsCurrent(watchdogGeneration, planGeneration)) return;
      }
    }
  }

  Future<void> _checkWake(
    BuiltInProxyNodePlan plan,
    _ReserveNodeState state,
    int generation,
  ) async {
    if (state.transitioning || monotonicNow() < state.retryUntil) return;
    final probe = healthProbe!;
    bool hasNetwork;
    try {
      hasNetwork = await probe.hasDeviceNetwork();
    } catch (_) {
      hasNetwork = false;
    }
    if (generation != _planGeneration) return;
    if (!hasNetwork) {
      state.failures = 0;
      return;
    }
    bool healthy;
    try {
      healthy = await probe.testDelay(
        proxyName: plan.activation!.watchGroup,
        urls: plan.activation!.wakeUrls,
      );
    } catch (_) {
      healthy = false;
    }
    if (generation != _planGeneration) return;
    if (healthy) {
      state.failures = 0;
      return;
    }
    state.failures++;
    if (state.failures >= plan.activation!.wakeFailures) {
      await _wakeNode(plan, state, generation);
    }
  }

  Future<void> _wakeNode(
    BuiltInProxyNodePlan plan,
    _ReserveNodeState state,
    int generation,
  ) async {
    if (state.transitioning || generation != _planGeneration) return;
    state.transitioning = true;
    try {
      await _serializeRuntimeMutation(() async {
        if (generation != _planGeneration ||
            !_currentPlans.any(
              (candidate) => candidate.nodeId == plan.nodeId,
            )) {
          return;
        }
        var attemptedAwakePlan = false;
        _awakeReserveNodeIds.add(plan.nodeId);
        try {
          final nodes = await _buildRuntimeNodes(_currentPlans);
          if (generation != _planGeneration) {
            await _restoreSleepingReserve(plan.nodeId, applyPlan: false);
            return;
          }
          attemptedAwakePlan = true;
          final result = await runtime.applyPlan(nodes);
          if (generation != _planGeneration) {
            await _restoreSleepingReserve(plan.nodeId);
            return;
          }
          if (!result.isReady) throw StateError(result.message);
          try {
            await _saveRuntimeNodes(nodes);
          } catch (_) {
            // Live activation succeeded; the next persistence point retries
            // the cold-start snapshot without tearing the node back down.
          }
          if (generation != _planGeneration) {
            await _restoreSleepingReserve(plan.nodeId);
            return;
          }
          final probe = healthProbe;
          if (probe != null) {
            final alive = await probe.testDelay(
              proxyName: plan.name,
              urls: plan.activation!.wakeUrls,
            );
            if (generation != _planGeneration) {
              await _restoreSleepingReserve(plan.nodeId);
              return;
            }
            if (!alive) {
              throw StateError(
                '${plan.type.label} node delay test failed after wake.',
              );
            }
          }
          state
            ..failures = 0
            ..retryUntil = Duration.zero
            ..idleSince = monotonicNow()
            ..nextCheck = monotonicNow() + plan.activation!.wakeInterval;
        } catch (_) {
          if (generation != _planGeneration) {
            await _restoreSleepingReserve(
              plan.nodeId,
              applyPlan: attemptedAwakePlan,
            );
            return;
          }
          _awakeReserveNodeIds.remove(plan.nodeId);
          state
            ..failures = 0
            ..idleSince = null
            ..retryUntil = monotonicNow() + plan.activation!.wakeRetryAfter
            ..nextCheck = monotonicNow() + plan.activation!.wakeRetryAfter;
          if (attemptedAwakePlan) {
            final sleepingNodes = await _buildRuntimeNodes(_currentPlans);
            if (generation != _planGeneration) {
              await _restoreSleepingReserve(plan.nodeId);
              return;
            }
            RuntimeNodePlanState? rollback;
            try {
              rollback = await runtime.applyPlan(sleepingNodes);
            } catch (_) {}
            if (generation != _planGeneration) {
              await _restoreSleepingReserve(plan.nodeId);
              return;
            }
            if (!(rollback?.isReady ?? false)) {
              try {
                await _saveRuntimeNodes(sleepingNodes);
              } catch (_) {}
              return;
            }
            try {
              await _saveRuntimeNodes(sleepingNodes);
            } catch (_) {}
          }
        }
      });
    } finally {
      state.transitioning = false;
    }
  }

  Future<void> _checkSleep(
    BuiltInProxyNodePlan plan,
    _ReserveNodeState state,
    int generation,
  ) async {
    final activation = plan.activation!;
    if (state.transitioning || activation.sleepIdle == Duration.zero) return;
    final probe = healthProbe!;
    List<List<String>> chains;
    try {
      chains = await probe.activeConnectionChains();
    } catch (_) {
      state.idleSince = null;
      return;
    }
    if (generation != _planGeneration) return;
    Map<String, String> selections;
    try {
      selections = await probe.selectedProxies(activation.containingGroups);
    } catch (_) {
      state.idleSince = null;
      return;
    }
    if (generation != _planGeneration) return;
    final inUse = chains.any((chain) => chain.contains(plan.name)) ||
        selections.values.any((selected) => selected == plan.name);
    if (inUse) {
      state.idleSince = null;
      return;
    }
    final now = monotonicNow();
    state.idleSince ??= now;
    if (now - state.idleSince! < activation.sleepIdle) return;
    await _sleepNode(plan, state, generation);
  }

  Future<void> _sleepNode(
    BuiltInProxyNodePlan plan,
    _ReserveNodeState state,
    int generation,
  ) async {
    if (state.transitioning || generation != _planGeneration) return;
    state.transitioning = true;
    try {
      await _serializeRuntimeMutation(() async {
        if (generation != _planGeneration) return;
        _awakeReserveNodeIds.remove(plan.nodeId);
        final nodes = await _buildRuntimeNodes(_currentPlans);
        if (generation != _planGeneration) {
          await _restoreAwakeReserve(plan.nodeId, applyPlan: false);
          return;
        }
        var attemptedSleepingPlan = false;
        try {
          attemptedSleepingPlan = true;
          final result = await runtime.applyPlan(nodes);
          if (generation != _planGeneration) {
            await _restoreAwakeReserve(plan.nodeId);
            return;
          }
          if (!result.isReady) throw StateError(result.message);
          state
            ..failures = 0
            ..idleSince = null
            ..nextCheck = monotonicNow() + plan.activation!.wakeInterval;
          try {
            await _saveRuntimeNodes(nodes);
          } catch (_) {
            // Live sleep succeeded; cold-start persistence is retried later.
          }
          if (generation != _planGeneration) {
            await _restoreAwakeReserve(plan.nodeId);
            return;
          }
        } catch (_) {
          if (generation != _planGeneration) {
            await _restoreAwakeReserve(
              plan.nodeId,
              applyPlan: attemptedSleepingPlan,
            );
            return;
          }
          _awakeReserveNodeIds.add(plan.nodeId);
          state
            ..idleSince = null
            ..nextCheck = monotonicNow() + plan.activation!.wakeInterval;
          if (attemptedSleepingPlan) {
            final awakeNodes = await _buildRuntimeNodes(_currentPlans);
            if (generation != _planGeneration) {
              await _restoreAwakeReserve(plan.nodeId);
              return;
            }
            try {
              await runtime.applyPlan(awakeNodes);
            } catch (_) {}
          }
        }
      });
    } finally {
      state.transitioning = false;
    }
  }

  Future<void> _restoreSleepingReserve(
    String nodeId, {
    bool applyPlan = true,
  }) async {
    _awakeReserveNodeIds.remove(nodeId);
    if (!applyPlan) return;
    final nodes = await _buildRuntimeNodes(_currentPlans);
    try {
      await runtime.applyPlan(nodes);
    } catch (_) {}
    try {
      await _saveRuntimeNodes(nodes);
    } catch (_) {}
  }

  Future<void> _restoreAwakeReserve(
    String nodeId, {
    bool applyPlan = true,
  }) async {
    _awakeReserveNodeIds.add(nodeId);
    if (!applyPlan) return;
    final nodes = await _buildRuntimeNodes(_currentPlans);
    try {
      await runtime.applyPlan(nodes);
    } catch (_) {}
    try {
      await _saveRuntimeNodes(nodes);
    } catch (_) {}
  }

  Future<T> _serializeRuntimeMutation<T>(Future<T> Function() action) async {
    final previous = _runtimeMutation;
    final done = Completer<void>();
    _runtimeMutation = done.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      done.complete();
    }
  }

  List<BuiltInProxyNodePlan> get _reservePlans =>
      _currentPlans.where(_isReserve).toList(growable: false);

  bool _isReserve(BuiltInProxyNodePlan plan) =>
      plan.activation?.isAuto ?? false;

  bool _watchdogIsCurrent(int watchdogGeneration, int planGeneration) =>
      watchdogGeneration == _watchdogGeneration &&
      planGeneration == _planGeneration;

  static Duration _readReserveMonotonicClock() =>
      _reserveMonotonicClock.elapsed;
}

class _ReserveNodeState {
  _ReserveNodeState({required this.nextCheck});

  Duration nextCheck;
  Duration retryUntil = Duration.zero;
  Duration? idleSince;
  int failures = 0;
  bool transitioning = false;
}
