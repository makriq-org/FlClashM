import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../common/common.dart';
import '../../models/models.dart';
import '../compile/product_compile.dart';
import 'engine_adapter.dart';

typedef RuntimeUpdateTask = FutureOr<void> Function();
typedef RuntimeUpdateTasks = List<RuntimeUpdateTask>;
typedef LoadCurrentRawProfileCallback = Future<RawProfile?> Function();
typedef ResolveProfilePatchCallback = ResolvedProfilePatch Function({
  required RawProfile? rawProfile,
  required ClashConfig patchConfig,
});
typedef BuildRuntimePlanCallback = Future<RuntimePlan> Function({
  required RawProfile? rawProfile,
  required ClashConfig patchConfig,
});
typedef ApplyRuntimePlanCallback = void Function(RuntimePlan runtimePlan);
typedef BuildCoreStateCallback = CoreState Function();
typedef BuildInitParamsCallback = Future<InitParams> Function();
typedef ResolveTunAccessCallback = FutureOr<ResolvedTunAccess> Function({
  required bool requestedTunEnable,
});

@immutable
class ResolvedTunAccess {
  const ResolvedTunAccess._({
    required this.shouldProceed,
    required this.enableTun,
  });

  const ResolvedTunAccess.proceed({required bool enableTun})
      : this._(shouldProceed: true, enableTun: enableTun);

  const ResolvedTunAccess.abort({bool enableTun = false})
      : this._(shouldProceed: false, enableTun: enableTun);

  final bool shouldProceed;
  final bool enableTun;
}

@immutable
class EngineRuntimePlanRequest {
  const EngineRuntimePlanRequest({
    required this.patchConfig,
    this.refreshProfile,
    this.resolveTunAccess,
    this.onPatchConfigResolved,
  });

  final ClashConfig patchConfig;
  final FutureOr<void> Function()? refreshProfile;
  final ResolveTunAccessCallback? resolveTunAccess;
  final ValueChanged<ClashConfig>? onPatchConfigResolved;
}

@immutable
class AppliedRuntimePlan {
  const AppliedRuntimePlan({
    required this.patchConfig,
    required this.runtimePlan,
  });

  final ClashConfig patchConfig;
  final RuntimePlan runtimePlan;
}

class EngineManager {
  EngineManager({
    required EngineAdapter adapter,
    required LoadCurrentRawProfileCallback loadCurrentRawProfile,
    required ResolveProfilePatchCallback resolveProfilePatch,
    required BuildRuntimePlanCallback buildRuntimePlan,
    required ApplyRuntimePlanCallback applyRuntimePlan,
    required BuildCoreStateCallback buildCoreState,
    required BuildInitParamsCallback buildInitParams,
  })  : _adapter = adapter,
        _loadCurrentRawProfile = loadCurrentRawProfile,
        _resolveProfilePatch = resolveProfilePatch,
        _buildRuntimePlan = buildRuntimePlan,
        _applyRuntimePlan = applyRuntimePlan,
        _buildCoreState = buildCoreState,
        _buildInitParams = buildInitParams;

  final EngineAdapter _adapter;
  final LoadCurrentRawProfileCallback _loadCurrentRawProfile;
  final ResolveProfilePatchCallback _resolveProfilePatch;
  final BuildRuntimePlanCallback _buildRuntimePlan;
  final ApplyRuntimePlanCallback _applyRuntimePlan;
  final BuildCoreStateCallback _buildCoreState;
  final BuildInitParamsCallback _buildInitParams;

  Timer? _updateTimer;
  RuntimeUpdateTasks _updateTasks = const [];
  DateTime? _startTime;

  DateTime? get startTime => _startTime;

  bool get isStarted => _startTime != null && _startTime!.isBeforeNow;

  Future<bool> waitUntilInitialized({
    int attempts = 1,
    Duration delay = Duration.zero,
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (await _adapter.isInitialized()) {
        return true;
      }
      if (i + 1 < attempts) {
        await Future.delayed(delay);
      }
    }
    return false;
  }

  Future<void> syncStartTime() async {
    _startTime = await _adapter.readStartTime();
  }

  Future<bool> start({
    RuntimeUpdateTasks? updateTasks,
    String? notificationTitle,
  }) async {
    final wasStarted = isStarted;
    final started = await _adapter.start(notificationTitle: notificationTitle);
    if (!started) {
      _startTime = null;
      _stopUpdateTasks();
      return false;
    }

    _startTime = wasStarted
        ? (_startTime ?? await _adapter.readStartTime())
        : DateTime.now();
    await _startUpdateTasks(updateTasks);
    return true;
  }

  Future<void> stop() async {
    _startTime = null;
    await _adapter.stop();
    _stopUpdateTasks();
  }

  Future<AppliedRuntimePlan?> setupRuntimePlan(
    EngineRuntimePlanRequest request, {
    ClashConfig? coldStartPatchConfig,
  }) async {
    final appliedRuntimePlan = await _compileRuntimePlan(request);
    if (appliedRuntimePlan == null) {
      return null;
    }

    final message = await _adapter.setupRuntimePlan(
      appliedRuntimePlan.runtimePlan,
    );
    if (message.isNotEmpty) {
      throw Exception(message);
    }

    if (coldStartPatchConfig != null) {
      await persistColdStart(pathConfig: coldStartPatchConfig);
    }

    return appliedRuntimePlan;
  }

  Future<bool> updateConfig(
    UpdateParams updateParams, {
    ResolveTunAccessCallback? resolveTunAccess,
    ClashConfig? coldStartPatchConfig,
  }) async {
    final resolvedUpdateParams = await _resolveUpdateParams(
      updateParams,
      resolveTunAccess,
    );
    if (resolvedUpdateParams == null) {
      return false;
    }

    final message = await _adapter.updateRuntimeConfig(resolvedUpdateParams);
    if (message.isNotEmpty) {
      throw Exception(message);
    }

    if (coldStartPatchConfig != null) {
      await persistColdStart(pathConfig: coldStartPatchConfig);
    }

    return true;
  }

  Future<bool> initializeCore({
    required EngineRuntimePlanRequest runtimePlanRequest,
    required ClashConfig coldStartPatchConfig,
  }) async {
    await _adapter.applyPendingUpdate();

    if (!await _adapter.isInitialized()) {
      await _adapter.initialize(
        initParams: await _buildInitParams(),
        state: _buildCoreState(),
      );
    }

    final appliedRuntimePlan = await setupRuntimePlan(
      runtimePlanRequest,
      coldStartPatchConfig: coldStartPatchConfig,
    );
    if (appliedRuntimePlan == null) {
      return false;
    }

    return true;
  }

  Future<bool> restart({
    required EngineRuntimePlanRequest runtimePlanRequest,
    required ClashConfig coldStartPatchConfig,
    bool resumeIfStarted = false,
    RuntimeUpdateTasks? updateTasks,
    String? notificationTitle,
  }) async {
    final wasStarted = resumeIfStarted && isStarted;
    if (wasStarted) {
      await stop();
    }

    await _adapter.prepareForRestart();

    final initialized = await initializeCore(
      runtimePlanRequest: runtimePlanRequest,
      coldStartPatchConfig: coldStartPatchConfig,
    );
    if (!initialized) {
      return false;
    }

    if (!wasStarted) {
      return true;
    }

    return start(
      updateTasks: updateTasks,
      notificationTitle: notificationTitle,
    );
  }

  Future<void> persistColdStart({required ClashConfig pathConfig}) async {
    try {
      final appliedRuntimePlan = await _compileRuntimePlan(
        EngineRuntimePlanRequest(patchConfig: pathConfig),
      );
      if (appliedRuntimePlan == null) {
        return;
      }

      await _adapter.persistColdStart(
        initParams: await _buildInitParams(),
        setupParams: appliedRuntimePlan.runtimePlan.toSetupParams(),
        state: _buildCoreState(),
      );
    } catch (e) {
      commonPrint.log("persistColdStartParams: $e");
    }
  }

  void pauseUpdateTasks() {
    _stopUpdateTasks();
  }

  Future<void> resumeUpdateTasks() async {
    if (!isStarted) {
      return;
    }
    await _startUpdateTasks();
  }

  Future<void> _startUpdateTasks([RuntimeUpdateTasks? updateTasks]) async {
    if (updateTasks != null) {
      _updateTasks = updateTasks;
    }

    if (_updateTimer?.isActive ?? false) {
      return;
    }

    await _executeUpdateTasks();
    _updateTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_startUpdateTasks());
    });
  }

  Future<void> _executeUpdateTasks() async {
    for (final task in _updateTasks) {
      await task();
    }
    _updateTimer = null;
  }

  void _stopUpdateTasks() {
    if (!(_updateTimer?.isActive ?? false)) {
      return;
    }
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  Future<AppliedRuntimePlan?> _compileRuntimePlan(
    EngineRuntimePlanRequest request,
  ) async {
    await request.refreshProfile?.call();

    final rawProfile = await _loadCurrentRawProfile();
    var patchConfig = request.patchConfig;
    final resolvedPatch = _resolveProfilePatch(
      rawProfile: rawProfile,
      patchConfig: patchConfig,
    );
    if (resolvedPatch.patchConfig != patchConfig) {
      patchConfig = resolvedPatch.patchConfig;
      request.onPatchConfigResolved?.call(patchConfig);
    }

    final realPatchConfig = await _resolvePatchConfig(
      patchConfig,
      request.resolveTunAccess,
    );
    if (realPatchConfig == null) {
      return null;
    }

    final runtimePlan = await _buildRuntimePlan(
      rawProfile: rawProfile,
      patchConfig: realPatchConfig,
    );
    _applyRuntimePlan(runtimePlan);

    return AppliedRuntimePlan(
      patchConfig: realPatchConfig,
      runtimePlan: runtimePlan,
    );
  }

  Future<ClashConfig?> _resolvePatchConfig(
    ClashConfig patchConfig,
    ResolveTunAccessCallback? resolveTunAccess,
  ) async {
    if (resolveTunAccess == null) {
      return patchConfig;
    }

    final resolvedTunAccess = await resolveTunAccess(
      requestedTunEnable: patchConfig.tun.enable,
    );
    if (!resolvedTunAccess.shouldProceed) {
      return null;
    }

    return patchConfig.copyWith.tun(enable: resolvedTunAccess.enableTun);
  }

  Future<UpdateParams?> _resolveUpdateParams(
    UpdateParams updateParams,
    ResolveTunAccessCallback? resolveTunAccess,
  ) async {
    if (resolveTunAccess == null) {
      return updateParams;
    }

    final resolvedTunAccess = await resolveTunAccess(
      requestedTunEnable: updateParams.tun.enable,
    );
    if (!resolvedTunAccess.shouldProceed) {
      return null;
    }

    return updateParams.copyWith.tun(enable: resolvedTunAccess.enableTun);
  }
}
