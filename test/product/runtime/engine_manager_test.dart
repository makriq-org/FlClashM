import 'dart:async';

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/product_runtime.dart';
import 'package:flclashx/product/security/product_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EngineManager', () {
    late _FakeEngineAdapter mihomoAdapter;
    late _FakeEngineAdapter naiveproxyAdapter;
    late RuntimeSelection runtimeSelection;
    late int applyRuntimePlanCalls;
    late EngineManager manager;

    EngineManager buildManager({
      LoadCurrentRawProfileCallback? loadCurrentRawProfile,
      EnforceSecurityPolicyCallback? enforceSecurityPolicy,
      BuildRuntimePlanCallback? buildRuntimePlan,
    }) =>
        EngineManager(
          runtimeRegistry: RuntimeRegistry(
            defaultSelection: const RuntimeSelection.mihomo(),
            engines: [
              EngineRuntimeRegistration(
                descriptor: const RuntimeDescriptor(
                  id: RuntimeId.mihomo,
                  role: RuntimeRole.engine,
                  capabilities: {RuntimeCapability.tun},
                ),
                availability: const RuntimeAvailability.supported(
                  updatePath: 'bundled',
                  rollbackPath: 'bundled',
                ),
                adapterFactory: () => mihomoAdapter,
              ),
              EngineRuntimeRegistration(
                descriptor: const RuntimeDescriptor(
                  id: RuntimeId.naiveproxy,
                  role: RuntimeRole.engine,
                  capabilities: {RuntimeCapability.localSocks5Listener},
                ),
                availability: const RuntimeAvailability.supported(
                  updatePath: 'pinned release',
                  rollbackPath: 'fallback to mihomo',
                ),
                adapterFactory: () => naiveproxyAdapter,
              ),
            ],
          ),
          loadCurrentRawProfile: loadCurrentRawProfile ?? () async => null,
          compileProfilePatch: ({
            required rawProfile,
            required patchConfig,
          }) =>
              CompiledProfilePatch(
            patchConfig: patchConfig,
            metadata: null,
          ),
          enforceSecurityPolicy: ({
            required compiledProfile,
          }) =>
              enforceSecurityPolicy?.call(compiledProfile: compiledProfile) ??
              SecuredProfilePatch(
                patchConfig: compiledProfile.patchConfig,
                metadata: compiledProfile.metadata,
              ),
          secureRuntimeUpdate: ({
            required updateParams,
          }) =>
              updateParams,
          buildRuntimePlan: buildRuntimePlan ??
              ({
                required rawProfile,
                required securedProfile,
                required runtimePatchConfig,
              }) async =>
                  RuntimePlan.empty(
                    selectedMap: const {},
                    testUrl: 'https://example.com',
                    runtime: runtimeSelection,
                  ),
          applyRuntimePlan: (_) {
            applyRuntimePlanCalls++;
          },
          buildCoreState: () => const CoreState(
            vpnProps: VpnProps(),
            onlyStatisticsProxy: false,
            currentProfileName: '',
          ),
          buildInitParams: () async =>
              const InitParams(homeDir: '/tmp/flclashm', version: 1),
        );

    setUp(() {
      mihomoAdapter = _FakeEngineAdapter();
      naiveproxyAdapter = _FakeEngineAdapter();
      runtimeSelection = const RuntimeSelection.mihomo();
      applyRuntimePlanCalls = 0;
      manager = buildManager();
    });

    test('re-attaches through adapter when runtime is already running',
        () async {
      mihomoAdapter.runtimeStartTime = DateTime(2026, 1, 2, 3, 4, 5);

      await manager.syncStartTime();
      final started = await manager.start();

      expect(started, isTrue);
      expect(mihomoAdapter.startCalls, 1);
      expect(manager.startTime, mihomoAdapter.runtimeStartTime);
    });

    test('uses adapter runtime start time on fresh attach without pre-sync',
        () async {
      mihomoAdapter.runtimeStartTime = DateTime(2026, 2, 3, 4, 5, 6);

      final started = await manager.start();

      expect(started, isTrue);
      expect(manager.startTime, mihomoAdapter.runtimeStartTime);
    });

    test('keeps successful start when runtime start time probe fails',
        () async {
      mihomoAdapter.readStartTimeError = StateError('runtime probe failed');
      final beforeStart = DateTime.now();

      final started = await manager.start();

      final afterStart = DateTime.now();
      expect(started, isTrue);
      expect(manager.startTime, isNotNull);
      expect(manager.startTime!.isBefore(beforeStart), isFalse);
      expect(manager.startTime!.isAfter(afterStart), isFalse);
    });

    test('persists cold-start params after setupRuntimePlan', () async {
      final applied = await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(applied, isNotNull);
      expect(mihomoAdapter.persistColdStartCalls, 1);
      expect(mihomoAdapter.lastPersistedRuntimePlan, isNotNull);
    });

    test('persists cold-start params after updateConfig', () async {
      final updated = await manager.updateConfig(
        const UpdateParams(
          tun: Tun(enable: true),
          mixedPort: defaultMixedPort,
          allowLan: false,
          findProcessMode: FindProcessMode.always,
          mode: Mode.rule,
          logLevel: LogLevel.error,
          ipv6: true,
          tcpConcurrent: true,
          externalController: ExternalControllerStatus.close,
          unifiedDelay: true,
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(updated, isTrue);
      expect(mihomoAdapter.updateConfigCalls, 1);
      expect(mihomoAdapter.persistColdStartCalls, 1);
      expect(mihomoAdapter.lastPersistedRuntimePlan, isNotNull);
    });

    test(
        'persists cold-start plan with tun disabled when hot plan enforces tun',
        () async {
      manager = buildManager(
        enforceSecurityPolicy: ({
          required compiledProfile,
        }) =>
            SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig.copyWith.tun(
            enable: true,
          ),
          metadata: compiledProfile.metadata,
          runtimeConstraints: const RuntimeSecurityConstraints(
            enforceTun: true,
          ),
        ),
        buildRuntimePlan: ({
          required rawProfile,
          required securedProfile,
          required runtimePatchConfig,
        }) async {
          final tunEnabled = securedProfile.runtimeConstraints.enforceTun
              ? true
              : runtimePatchConfig.tun.enable;
          return RuntimePlan(
            config: {
              'tun': {
                'enable': tunEnabled,
              },
            },
            selectedMap: const {},
            testUrl: 'https://example.com',
            runtime: runtimeSelection,
            metadata: null,
          );
        },
      );

      final applied = await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(
            tun: Tun(enable: true),
          ),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(applied, isNotNull);
      expect(
        mihomoAdapter.lastPersistedRuntimePlan?.config['tun'],
        isA<Map<String, dynamic>>().having(
          (tun) => tun['enable'],
          'enable',
          isFalse,
        ),
      );
    });

    test(
        'loads raw profile once when setupRuntimePlan also persists cold-start',
        () async {
      var loadCurrentRawProfileCalls = 0;
      manager = buildManager(
        loadCurrentRawProfile: () async {
          loadCurrentRawProfileCalls++;
          return null;
        },
      );

      final applied = await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(applied, isNotNull);
      expect(loadCurrentRawProfileCalls, 1);
      expect(mihomoAdapter.persistColdStartCalls, 1);
    });

    test('does not wait for cold-start persistence on setupRuntimePlan',
        () async {
      final persistStarted = Completer<void>();
      final persistCompleted = Completer<void>();
      mihomoAdapter
        ..onPersistColdStart = () {
          if (!persistStarted.isCompleted) {
            persistStarted.complete();
          }
        }
        ..persistColdStartCompleter = persistCompleted;

      final applied = await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );

      expect(applied, isNotNull);
      expect(persistCompleted.isCompleted, isFalse);

      await persistStarted.future.timeout(const Duration(seconds: 1));
      expect(mihomoAdapter.persistColdStartCalls, 1);

      persistCompleted.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('serializes cold-start persistence and keeps the latest snapshot',
        () async {
      final firstPersistStarted = Completer<void>();
      final secondPersistStarted = Completer<void>();
      final firstPersistCompleted = Completer<void>();
      manager = buildManager(
        buildRuntimePlan: ({
          required rawProfile,
          required securedProfile,
          required runtimePatchConfig,
        }) async =>
            RuntimePlan(
          config: {
            'mixed-port': runtimePatchConfig.mixedPort,
            'tun': {
              'enable': runtimePatchConfig.tun.enable,
            },
          },
          selectedMap: const {},
          testUrl: 'https://example.com',
          runtime: runtimeSelection,
          metadata: null,
        ),
      );
      mihomoAdapter
        ..onPersistColdStartCall = (callIndex, _) {
          if (callIndex == 1 && !firstPersistStarted.isCompleted) {
            firstPersistStarted.complete();
          }
          if (callIndex == 2 && !secondPersistStarted.isCompleted) {
            secondPersistStarted.complete();
          }
        }
        ..persistColdStartCompleters = [firstPersistCompleted];

      await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(
            mixedPort: 10001,
          ),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );
      await firstPersistStarted.future.timeout(const Duration(seconds: 1));

      await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(
            mixedPort: 10002,
          ),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(secondPersistStarted.isCompleted, isFalse);

      firstPersistCompleted.complete();
      await secondPersistStarted.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(mihomoAdapter.persistColdStartCalls, 2);
      expect(
        mihomoAdapter.lastPersistedRuntimePlan?.config['mixed-port'],
        10002,
      );
    });

    test('secures live runtime updates before adapter update', () async {
      manager = EngineManager(
        runtimeRegistry: RuntimeRegistry(
          defaultSelection: const RuntimeSelection.mihomo(),
          engines: [
            EngineRuntimeRegistration(
              descriptor: const RuntimeDescriptor(
                id: RuntimeId.mihomo,
                role: RuntimeRole.engine,
                capabilities: {RuntimeCapability.tun},
              ),
              availability: const RuntimeAvailability.supported(
                updatePath: 'bundled',
                rollbackPath: 'bundled',
              ),
              adapterFactory: () => mihomoAdapter,
            ),
          ],
        ),
        loadCurrentRawProfile: () async => null,
        compileProfilePatch: ({
          required rawProfile,
          required patchConfig,
        }) =>
            CompiledProfilePatch(
          patchConfig: patchConfig,
          metadata: null,
        ),
        enforceSecurityPolicy: ({
          required compiledProfile,
        }) =>
            SecuredProfilePatch(
          patchConfig: compiledProfile.patchConfig,
          metadata: compiledProfile.metadata,
        ),
        secureRuntimeUpdate: ({
          required updateParams,
        }) =>
            updateParams.copyWith(
          tun: updateParams.tun.copyWith(enable: true),
        ),
        buildRuntimePlan: ({
          required rawProfile,
          required securedProfile,
          required runtimePatchConfig,
        }) async =>
            RuntimePlan.empty(
          selectedMap: const {},
          testUrl: 'https://example.com',
          runtime: runtimeSelection,
        ),
        applyRuntimePlan: (_) {
          applyRuntimePlanCalls++;
        },
        buildCoreState: () => const CoreState(
          vpnProps: VpnProps(),
          onlyStatisticsProxy: false,
          currentProfileName: '',
        ),
        buildInitParams: () async =>
            const InitParams(homeDir: '/tmp/flclashm', version: 1),
      );

      final updated = await manager.updateConfig(
        const UpdateParams(
          tun: Tun(enable: false),
          mixedPort: defaultMixedPort,
          allowLan: false,
          findProcessMode: FindProcessMode.always,
          mode: Mode.rule,
          logLevel: LogLevel.error,
          ipv6: true,
          tcpConcurrent: true,
          externalController: ExternalControllerStatus.close,
          unifiedDelay: true,
        ),
      );

      expect(updated, isTrue);
      expect(mihomoAdapter.updateConfigCalls, 1);
      expect(mihomoAdapter.lastUpdateParams?.tun.enable, isTrue);
    });

    test('initializes the engine selected by runtime plan', () async {
      naiveproxyAdapter.isInitializedValue = false;
      runtimeSelection = const RuntimeSelection(engine: RuntimeId.naiveproxy);

      final initialized = await manager.initializeCore(
        runtimePlanRequest: const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(),
        ),
        coldStartPatchConfig: const ClashConfig(),
      );

      expect(initialized, isTrue);
      expect(naiveproxyAdapter.applyPendingUpdateCalls, 1);
      expect(naiveproxyAdapter.initializeCalls, 1);
      expect(naiveproxyAdapter.setupRuntimePlanCalls, 1);
      expect(mihomoAdapter.applyPendingUpdateCalls, 0);
      expect(mihomoAdapter.initializeCalls, 0);
      expect(manager.activeEngineId, RuntimeId.naiveproxy);
    });

    test('can initialize core without applying runtime plan', () async {
      mihomoAdapter.isInitializedValue = false;

      final initialized = await manager.initializeCore(
        runtimePlanRequest: const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(),
        ),
        coldStartPatchConfig: const ClashConfig(),
        setupRuntimePlan: false,
      );

      expect(initialized, isTrue);
      expect(mihomoAdapter.applyPendingUpdateCalls, 1);
      expect(mihomoAdapter.initializeCalls, 1);
      expect(mihomoAdapter.setupRuntimePlanCalls, 0);
      expect(manager.activeEngineId, RuntimeId.mihomo);
    });

    test('rejects runtime switch while started', () async {
      final started = await manager.start();
      expect(started, isTrue);

      runtimeSelection = const RuntimeSelection(engine: RuntimeId.naiveproxy);

      await expectLater(
        () => manager.setupRuntimePlan(
          const EngineRuntimePlanRequest(
            patchConfig: ClashConfig(),
          ),
        ),
        throwsA(
          isA<UnsupportedRuntimeSelectionException>().having(
            (error) => error.message,
            'message',
            contains('requires a full stop/restart boundary'),
          ),
        ),
      );
      expect(naiveproxyAdapter.setupRuntimePlanCalls, 0);
    });

    test('keeps the active adapter when a runtime switch setup fails',
        () async {
      runtimeSelection = const RuntimeSelection(engine: RuntimeId.naiveproxy);
      naiveproxyAdapter.setupRuntimePlanMessage = 'setup failed';

      await expectLater(
        () => manager.setupRuntimePlan(
          const EngineRuntimePlanRequest(
            patchConfig: ClashConfig(),
          ),
        ),
        throwsA(isA<Exception>()),
      );

      expect(manager.activeEngineId, RuntimeId.mihomo);
      expect(naiveproxyAdapter.setupRuntimePlanCalls, 1);
      expect(mihomoAdapter.setupRuntimePlanCalls, 0);
      expect(applyRuntimePlanCalls, 0);
    });

    test('keeps runtime attached state when adapter stop fails', () async {
      mihomoAdapter.runtimeStartTime = DateTime(2026, 3, 4, 5, 6, 7);
      await manager.syncStartTime();
      mihomoAdapter.stopError = StateError('listener stop failed');

      await expectLater(
        manager.stop,
        throwsA(isA<StateError>()),
      );

      expect(manager.startTime, mihomoAdapter.runtimeStartTime);
      expect(mihomoAdapter.stopCalls, 1);
    });
  });
}

class _FakeEngineAdapter implements EngineAdapter {
  DateTime? runtimeStartTime;
  bool isInitializedValue = true;
  String setupRuntimePlanMessage = '';
  bool startResult = true;
  Error? readStartTimeError;
  Error? stopError;
  int applyPendingUpdateCalls = 0;
  int initializeCalls = 0;
  int setupRuntimePlanCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int updateConfigCalls = 0;
  int persistColdStartCalls = 0;
  RuntimePlan? lastPersistedRuntimePlan;
  RuntimePlan? lastRequestedPersistedRuntimePlan;
  UpdateParams? lastUpdateParams;
  void Function()? onPersistColdStart;
  void Function(int callIndex, RuntimePlan runtimePlan)? onPersistColdStartCall;
  Completer<void>? persistColdStartCompleter;
  List<Completer<void>> persistColdStartCompleters = const [];

  @override
  Future<void> applyPendingUpdate() async {
    applyPendingUpdateCalls++;
  }

  @override
  Future<void> prepareForRestart() async {}

  @override
  Future<bool> isInitialized() async => isInitializedValue;

  @override
  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  }) async {
    initializeCalls++;
    isInitializedValue = true;
  }

  @override
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) async {
    setupRuntimePlanCalls++;
    return setupRuntimePlanMessage;
  }

  @override
  Future<String> updateRuntimeConfig(UpdateParams updateParams) async {
    updateConfigCalls++;
    lastUpdateParams = updateParams;
    return '';
  }

  @override
  Future<bool> start({String? notificationTitle}) async {
    startCalls++;
    return startResult;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopError != null) {
      throw stopError!;
    }
  }

  @override
  Future<DateTime?> readStartTime() async {
    if (readStartTimeError != null) {
      throw readStartTimeError!;
    }
    return runtimeStartTime;
  }

  @override
  Future<void> persistColdStart({
    required InitParams initParams,
    required RuntimePlan runtimePlan,
    required CoreState state,
  }) async {
    persistColdStartCalls++;
    final callIndex = persistColdStartCalls;
    lastRequestedPersistedRuntimePlan = runtimePlan;
    onPersistColdStart?.call();
    onPersistColdStartCall?.call(callIndex, runtimePlan);
    if (callIndex <= persistColdStartCompleters.length) {
      await persistColdStartCompleters[callIndex - 1].future;
    }
    if (persistColdStartCompleter != null) {
      await persistColdStartCompleter!.future;
    }
    lastPersistedRuntimePlan = runtimePlan;
  }
}
