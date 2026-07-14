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
typedef BuildCoreStateCallback = CoreState Function({
  AccessControl? profileAccessControl,
});
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
    required this.rawProfile,
    required this.securedProfile,
  });

  final AppliedRuntimePlan appliedRuntimePlan;
  final ResolvedRuntimeSelection resolvedRuntime;
  final RawProfile? rawProfile;
  final SecuredProfilePatch securedProfile;
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
  int _tasksEpoch = 0;
  RuntimeUpdateTasks _updateTasks = const [];
  DateTime? _startTime;
  _CompiledRuntimePlan? _lastCompiledRuntimePlan;
  Future<void> _coldStartPersistChain = Future<void>.value();

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

  /// Returns true when the probe succeeded and the start time is now KNOWN
  /// (possibly null, meaning "confirmed stopped"). Returns false when the
  /// runtime state is UNKNOWN (probe failed/timed out, e.g. a slow service
  /// bind on cold start) — callers must not treat "unknown" as "stopped",
  /// otherwise they'd tear down a possibly-live tunnel.
  Future<bool> syncStartTime() async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        _startTime = await _adapter.readStartTime();
        return true;
      } catch (e) {
        commonPrint.log("syncStartTime probe failed (#$attempt): $e");
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return false;
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

    _syncCachedRuntimePlanWithUpdate(resolvedUpdateParams);

    if (coldStartPatchConfig != null) {
      _persistColdStartInBackground(
        coldStartPatchConfig: coldStartPatchConfig,
      );
    }

    return true;
  }

  Future<bool> initializeCore({
    required EngineRuntimePlanRequest runtimePlanRequest,
    required ClashConfig coldStartPatchConfig,
    bool setupRuntimePlan = true,
  }) async {
    final compiledRuntimePlan = await _compileRuntimePlan(runtimePlanRequest);
    if (compiledRuntimePlan == null) {
      return false;
    }

    final targetAdapter = compiledRuntimePlan.resolvedRuntime.engine.adapter;

    if (!await targetAdapter.isInitialized()) {
      await targetAdapter.initialize(
        initParams: await _buildInitParams(),
        state: _buildCoreState(
          profileAccessControl: compiledRuntimePlan
              .appliedRuntimePlan.runtimePlan.profileAccessControl,
        ),
      );
    }

    if (!setupRuntimePlan) {
      return true;
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
    final compiledRuntimePlan = _lastCompiledRuntimePlan;
    try {
      await _enqueueColdStartPersistence(() async {
        if (compiledRuntimePlan == null) {
          await _persistColdStartWithoutCompiledRuntimePlan(
            coldStartPatchConfig: pathConfig,
          );
          return;
        }

        await _persistColdStartFromCompiledRuntimePlan(
          compiledRuntimePlan,
          coldStartPatchConfig: pathConfig,
        );
      });
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

    final epoch = ++_tasksEpoch;
    await _executeUpdateTasks();
    // _stopUpdateTasks() (or a restart) bumped the epoch while the executor
    // was in flight: don't reschedule, otherwise the poll loop resurrects
    // itself and keeps hammering a (possibly dead) remote forever after a
    // stop.
    if (epoch != _tasksEpoch) {
      return;
    }
    _updateTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_startUpdateTasks());
    });
  }

  Future<void> _executeUpdateTasks() async {
    for (final task in _updateTasks) {
      // Isolate failures: one throwing task must not kill the whole loop
      // (which would silently freeze traffic/runtime counters while the
      // tunnel is live).
      try {
        await task();
      } catch (e) {
        commonPrint.log("executeUpdateTasks error: $e");
      }
    }
    _updateTimer = null;
  }

  void _stopUpdateTasks() {
    // Always invalidate the in-flight cycle (the executor nulls `_updateTimer`
    // mid-run, so an isActive early-return would let a stop slip through and
    // the loop would reschedule anyway).
    _tasksEpoch++;
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
      rawProfile: rawProfile,
      securedProfile: securedProfile,
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
    _lastCompiledRuntimePlan = compiledRuntimePlan;
    _applyRuntimePlan(compiledRuntimePlan.appliedRuntimePlan.runtimePlan);

    if (coldStartPatchConfig != null) {
      _persistColdStartInBackground(
        coldStartPatchConfig: coldStartPatchConfig,
      );
    }
  }

  void _persistColdStartInBackground({
    required ClashConfig coldStartPatchConfig,
  }) {
    final compiledRuntimePlan = _lastCompiledRuntimePlan;
    unawaited(
      _enqueueColdStartPersistence(() async {
        if (compiledRuntimePlan == null) {
          await _persistColdStartWithoutCompiledRuntimePlan(
            coldStartPatchConfig: coldStartPatchConfig,
          );
          return;
        }

        await _persistColdStartFromCompiledRuntimePlan(
          compiledRuntimePlan,
          coldStartPatchConfig: coldStartPatchConfig,
        );
      }).catchError((Object error) {
        commonPrint.log("persistColdStartParams: $error");
      }),
    );
  }

  Future<void> _enqueueColdStartPersistence(
    Future<void> Function() persistTask,
  ) {
    final queuedTask = _coldStartPersistChain.then((_) => persistTask());
    _coldStartPersistChain = queuedTask.catchError((_) {});
    return queuedTask;
  }

  Future<void> _persistColdStartFromCompiledRuntimePlan(
    _CompiledRuntimePlan compiledRuntimePlan, {
    required ClashConfig coldStartPatchConfig,
  }) async {
    final resolvedColdStartPatchConfig = _resolveColdStartPatchConfig(
      runtimePatchConfig: compiledRuntimePlan.appliedRuntimePlan.patchConfig,
      coldStartPatchConfig: coldStartPatchConfig,
    );
    final coldStartSecuredProfile = SecuredProfilePatch(
      patchConfig: resolvedColdStartPatchConfig,
      metadata: compiledRuntimePlan.securedProfile.metadata,
      runtimeConstraints: _resolveColdStartRuntimeConstraints(
        runtimeConstraints:
            compiledRuntimePlan.securedProfile.runtimeConstraints,
        coldStartPatchConfig: resolvedColdStartPatchConfig,
      ),
    );
    final coldStartRuntimePlan = await _buildRuntimePlan(
      rawProfile: compiledRuntimePlan.rawProfile,
      securedProfile: coldStartSecuredProfile,
      runtimePatchConfig: resolvedColdStartPatchConfig,
    );
    final resolvedRuntime =
        _resolveRuntimeSelection(coldStartRuntimePlan.runtime);
    await resolvedRuntime.engine.adapter.persistColdStart(
      initParams: await _buildInitParams(),
      runtimePlan: coldStartRuntimePlan,
      state: _buildCoreState(
        profileAccessControl: coldStartRuntimePlan.profileAccessControl,
      ),
    );
  }

  Future<void> _persistColdStartWithoutCompiledRuntimePlan({
    required ClashConfig coldStartPatchConfig,
  }) async {
    final coldStartRuntimePlan = await _buildRuntimePlan(
      rawProfile: null,
      securedProfile: SecuredProfilePatch(
        patchConfig: coldStartPatchConfig,
        metadata: null,
      ),
      runtimePatchConfig: coldStartPatchConfig,
    );
    final resolvedRuntime =
        _resolveRuntimeSelection(coldStartRuntimePlan.runtime);
    await resolvedRuntime.engine.adapter.persistColdStart(
      initParams: await _buildInitParams(),
      runtimePlan: coldStartRuntimePlan,
      state: _buildCoreState(
        profileAccessControl: coldStartRuntimePlan.profileAccessControl,
      ),
    );
  }

  ClashConfig _resolveColdStartPatchConfig({
    required ClashConfig runtimePatchConfig,
    required ClashConfig coldStartPatchConfig,
  }) =>
      runtimePatchConfig.copyWith.tun(enable: coldStartPatchConfig.tun.enable);

  RuntimeSecurityConstraints _resolveColdStartRuntimeConstraints({
    required RuntimeSecurityConstraints runtimeConstraints,
    required ClashConfig coldStartPatchConfig,
  }) =>
      coldStartPatchConfig.tun.enable
          ? runtimeConstraints
          : const RuntimeSecurityConstraints();

  void _syncCachedRuntimePlanWithUpdate(UpdateParams updateParams) {
    final compiledRuntimePlan = _lastCompiledRuntimePlan;
    if (compiledRuntimePlan == null) {
      return;
    }

    final updatedPatchConfig = _applyUpdateParamsToPatchConfig(
      compiledRuntimePlan.appliedRuntimePlan.patchConfig,
      updateParams,
    );
    final updatedRuntimePlan = _applyUpdateParamsToRuntimePlan(
      compiledRuntimePlan.appliedRuntimePlan.runtimePlan,
      updateParams,
    );
    final updatedMetadata = _applyUpdateParamsToMetadata(
      compiledRuntimePlan.securedProfile.metadata,
      updateParams,
    );
    _lastCompiledRuntimePlan = _CompiledRuntimePlan(
      appliedRuntimePlan: AppliedRuntimePlan(
        patchConfig: updatedPatchConfig,
        runtimePlan: updatedRuntimePlan,
      ),
      resolvedRuntime: compiledRuntimePlan.resolvedRuntime,
      rawProfile: compiledRuntimePlan.rawProfile,
      securedProfile: SecuredProfilePatch(
        patchConfig: updatedPatchConfig,
        metadata: updatedMetadata,
        runtimeConstraints:
            compiledRuntimePlan.securedProfile.runtimeConstraints,
      ),
    );
  }

  ClashConfig _applyUpdateParamsToPatchConfig(
    ClashConfig patchConfig,
    UpdateParams updateParams,
  ) =>
      patchConfig.copyWith(
        tun: updateParams.tun,
        allowLan: updateParams.allowLan,
        findProcessMode: updateParams.findProcessMode,
        mode: updateParams.mode,
        logLevel: updateParams.logLevel,
        ipv6: updateParams.ipv6,
        tcpConcurrent: updateParams.tcpConcurrent,
        externalController: updateParams.externalController,
        unifiedDelay: updateParams.unifiedDelay,
        mixedPort: updateParams.mixedPort,
      );

  RuntimePlan _applyUpdateParamsToRuntimePlan(
    RuntimePlan runtimePlan,
    UpdateParams updateParams,
  ) =>
      RuntimePlan(
        config: _applyUpdateParamsToConfig(runtimePlan.config, updateParams),
        selectedMap: runtimePlan.selectedMap,
        testUrl: runtimePlan.testUrl,
        runtime: runtimePlan.runtime,
        files: runtimePlan.files,
        builtInProxyNodes: runtimePlan.builtInProxyNodes,
        metadata:
            _applyUpdateParamsToMetadata(runtimePlan.metadata, updateParams),
        profileAccessControl: runtimePlan.profileAccessControl,
      );

  Map<String, dynamic> _applyUpdateParamsToConfig(
    Map<String, dynamic> config,
    UpdateParams updateParams,
  ) {
    final updatedConfig = Map<String, dynamic>.from(config);
    final updatedTun = Map<String, dynamic>.from(
      switch (updatedConfig['tun']) {
        final Map<dynamic, dynamic> tun => tun.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        _ => const <String, dynamic>{},
      },
    );

    updatedTun['enable'] = updateParams.tun.enable;
    updatedTun['device'] = updateParams.tun.device;
    updatedTun['dns-hijack'] = updateParams.tun.dnsHijack;
    updatedTun['stack'] = updateParams.tun.stack.name;
    updatedTun['route-address'] = updateParams.tun.routeAddress;
    updatedTun['auto-route'] = updateParams.tun.autoRoute;

    updatedConfig['tun'] = updatedTun;
    updatedConfig['allow-lan'] = updateParams.allowLan;
    updatedConfig['find-process-mode'] = updateParams.findProcessMode.name;
    updatedConfig['mode'] = updateParams.mode.name;
    updatedConfig['log-level'] = updateParams.logLevel.name;
    updatedConfig['ipv6'] = updateParams.ipv6;
    updatedConfig['tcp-concurrent'] = updateParams.tcpConcurrent;
    updatedConfig['external-controller'] =
        updateParams.externalController.value;
    updatedConfig['unified-delay'] = updateParams.unifiedDelay;
    updatedConfig['mixed-port'] = updateParams.mixedPort;
    return updatedConfig;
  }

  CompiledProfileMetadata? _applyUpdateParamsToMetadata(
    CompiledProfileMetadata? metadata,
    UpdateParams updateParams,
  ) =>
      metadata == null
          ? null
          : CompiledProfileMetadata(
              externalController: updateParams.externalController.value,
              secret: metadata.secret,
              tcpConcurrent: updateParams.tcpConcurrent,
              unifiedDelay: updateParams.unifiedDelay,
              logLevel: updateParams.logLevel.name,
              keepAliveInterval: metadata.keepAliveInterval,
              groupDescriptions: metadata.groupDescriptions,
            );

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
