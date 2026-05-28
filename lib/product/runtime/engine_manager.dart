import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../common/common.dart';
import '../../models/models.dart';
import '../compile/product_compile.dart';
import '../security/product_security.dart';
import 'engine_adapter.dart';
import 'runtime_registry.dart';
import 'runtime_types.dart';

typedef RuntimeUpdateTask = FutureOr<void> Function();
typedef RuntimeUpdateTasks = List<RuntimeUpdateTask>;
typedef LoadCurrentRawProfileCallback = Future<RawProfile?> Function();
typedef CompileProfilePatchCallback = CompiledProfilePatch Function({
  required RawProfile? rawProfile,
  required ClashConfig patchConfig,
});
typedef EnforceSecurityPolicyCallback = SecuredProfilePatch Function({
  required CompiledProfilePatch compiledProfile,
});
typedef SecureRuntimeUpdateCallback = UpdateParams Function({
  required UpdateParams updateParams,
});
typedef BuildRuntimePlanCallback = Future<RuntimePlan> Function({
  required RawProfile? rawProfile,
  required SecuredProfilePatch securedProfile,
  required ClashConfig runtimePatchConfig,
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

@immutable
class _CompiledRuntimePlan {
  const _CompiledRuntimePlan({
    required this.appliedRuntimePlan,
    required this.resolvedRuntime,
  });

  final AppliedRuntimePlan appliedRuntimePlan;
  final ResolvedRuntimeSelection resolvedRuntime;
}

class EngineManager {
  EngineManager({
    required RuntimeRegistry runtimeRegistry,
    required LoadCurrentRawProfileCallback loadCurrentRawProfile,
    required CompileProfilePatchCallback compileProfilePatch,
    required EnforceSecurityPolicyCallback enforceSecurityPolicy,
    required SecureRuntimeUpdateCallback secureRuntimeUpdate,
    required BuildRuntimePlanCallback buildRuntimePlan,
    required ApplyRuntimePlanCallback applyRuntimePlan,
    required BuildCoreStateCallback buildCoreState,
    required BuildInitParamsCallback buildInitParams,
  })  : _runtimeRegistry = runtimeRegistry,
        _activeRuntime = runtimeRegistry.resolveSelection(),
        _loadCurrentRawProfile = loadCurrentRawProfile,
        _compileProfilePatch = compileProfilePatch,
        _enforceSecurityPolicy = enforceSecurityPolicy,
        _secureRuntimeUpdate = secureRuntimeUpdate,
        _buildRuntimePlan = buildRuntimePlan,
        _applyRuntimePlan = applyRuntimePlan,
        _buildCoreState = buildCoreState,
        _buildInitParams = buildInitParams;

  final RuntimeRegistry _runtimeRegistry;
  ResolvedRuntimeSelection _activeRuntime;
  final LoadCurrentRawProfileCallback _loadCurrentRawProfile;
  final CompileProfilePatchCallback _compileProfilePatch;
  final EnforceSecurityPolicyCallback _enforceSecurityPolicy;
  final SecureRuntimeUpdateCallback _secureRuntimeUpdate;
  final BuildRuntimePlanCallback _buildRuntimePlan;
  final ApplyRuntimePlanCallback _applyRuntimePlan;
  final BuildCoreStateCallback _buildCoreState;
  final BuildInitParamsCallback _buildInitParams;

  Timer? _updateTimer;
  RuntimeUpdateTasks _updateTasks = const [];
  DateTime? _startTime;

  EngineAdapter get _adapter => _activeRuntime.engine.adapter;

  RuntimeId get activeEngineId =>
      _activeRuntime.engine.registration.descriptor.id;

  RuntimeSelection get activeRuntimeSelection => _activeRuntime.selection;

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

    DateTime? runtimeStartTime;
    try {
      runtimeStartTime = await _adapter.readStartTime();
    } catch (e) {
      commonPrint.log(
        "EngineManager failed to read runtime start time after start: $e",
      );
    }
    _startTime = runtimeStartTime ?? (wasStarted ? _startTime : DateTime.now());
    await _startUpdateTasks(updateTasks);
    return true;
  }

  Future<void> stop() async {
    Object? error;
    StackTrace? stackTrace;

    try {
      await _adapter.stop();
    } catch (e, s) {
      error = e;
      stackTrace = s;
    } finally {
      _stopUpdateTasks();
    }

    if (error == null) {
      _startTime = null;
      return;
    }

    try {
      _startTime = await _adapter.readStartTime();
    } catch (_) {}

    Error.throwWithStackTrace(error, stackTrace!);
  }

  Future<AppliedRuntimePlan?> setupRuntimePlan(
    EngineRuntimePlanRequest request, {
    ClashConfig? coldStartPatchConfig,
  }) async {
    final compiledRuntimePlan = await _compileRuntimePlan(request);
    if (compiledRuntimePlan == null) {
      return null;
    }

    await _setupCompiledRuntimePlan(
      compiledRuntimePlan,
      coldStartPatchConfig: coldStartPatchConfig,
    );

    return compiledRuntimePlan.appliedRuntimePlan;
  }

  Future<bool> updateConfig(
    UpdateParams updateParams, {
    ResolveTunAccessCallback? resolveTunAccess,
    ClashConfig? coldStartPatchConfig,
  }) async {
    final securedUpdateParams = _secureRuntimeUpdate(
      updateParams: updateParams,
    );
    final resolvedUpdateParams = await _resolveUpdateParams(
      securedUpdateParams,
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
    final compiledRuntimePlan = await _compileRuntimePlan(runtimePlanRequest);
    if (compiledRuntimePlan == null) {
      return false;
    }

    final targetAdapter = compiledRuntimePlan.resolvedRuntime.engine.adapter;

    await targetAdapter.applyPendingUpdate();

    if (!await targetAdapter.isInitialized()) {
      await targetAdapter.initialize(
        initParams: await _buildInitParams(),
        state: _buildCoreState(),
      );
    }

    await _setupCompiledRuntimePlan(
      compiledRuntimePlan,
      coldStartPatchConfig: coldStartPatchConfig,
    );

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
      final compiledRuntimePlan = await _compileRuntimePlan(
        EngineRuntimePlanRequest(patchConfig: pathConfig),
      );
      if (compiledRuntimePlan == null) {
        return;
      }

      await compiledRuntimePlan.resolvedRuntime.engine.adapter.persistColdStart(
        initParams: await _buildInitParams(),
        setupParams:
            compiledRuntimePlan.appliedRuntimePlan.runtimePlan.toSetupParams(),
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

  Future<_CompiledRuntimePlan?> _compileRuntimePlan(
    EngineRuntimePlanRequest request,
  ) async {
    await request.refreshProfile?.call();

    final rawProfile = await _loadCurrentRawProfile();
    final compiledProfile = _compileProfilePatch(
      rawProfile: rawProfile,
      patchConfig: request.patchConfig,
    );
    final securedProfile = _enforceSecurityPolicy(
      compiledProfile: compiledProfile,
    );
    final patchConfig = securedProfile.patchConfig;
    if (patchConfig != request.patchConfig) {
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
      securedProfile: securedProfile,
      runtimePatchConfig: realPatchConfig,
    );
    final resolvedRuntime = _resolveRuntimeSelection(runtimePlan.runtime);

    return _CompiledRuntimePlan(
      appliedRuntimePlan: AppliedRuntimePlan(
        patchConfig: realPatchConfig,
        runtimePlan: runtimePlan,
      ),
      resolvedRuntime: resolvedRuntime,
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

  Future<void> _setupCompiledRuntimePlan(
    _CompiledRuntimePlan compiledRuntimePlan, {
    ClashConfig? coldStartPatchConfig,
  }) async {
    final targetAdapter = compiledRuntimePlan.resolvedRuntime.engine.adapter;
    final message = await targetAdapter.setupRuntimePlan(
      compiledRuntimePlan.appliedRuntimePlan.runtimePlan,
    );
    if (message.isNotEmpty) {
      throw Exception(message);
    }

    _activeRuntime = compiledRuntimePlan.resolvedRuntime;
    _applyRuntimePlan(compiledRuntimePlan.appliedRuntimePlan.runtimePlan);

    if (coldStartPatchConfig != null) {
      await persistColdStart(pathConfig: coldStartPatchConfig);
    }
  }

  ResolvedRuntimeSelection _resolveRuntimeSelection(
      RuntimeSelection selection) {
    if (_activeRuntime.selection == selection) {
      return _activeRuntime;
    }
    if (isStarted) {
      throw UnsupportedRuntimeSelectionException(
        'Runtime switch from ${_activeRuntime.selection.engine.label} '
        'to ${selection.engine.label} requires a full stop/restart boundary.',
      );
    }
    return _runtimeRegistry.resolveSelection(selection);
  }
}
