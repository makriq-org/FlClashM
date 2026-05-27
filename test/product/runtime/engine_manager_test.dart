import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/product_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EngineManager', () {
    late _FakeEngineAdapter mihomoAdapter;
    late _FakeEngineAdapter naiveproxyAdapter;
    late RuntimeSelection runtimeSelection;
    late int applyRuntimePlanCalls;
    late EngineManager manager;

    EngineManager buildManager() => EngineManager(
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
          loadCurrentRawProfile: () async => null,
          resolveProfilePatch: ({
            required rawProfile,
            required patchConfig,
          }) =>
              ResolvedProfilePatch(
            patchConfig: patchConfig,
            metadata: null,
          ),
          buildRuntimePlan: ({
            required rawProfile,
            required patchConfig,
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

    test('persists cold-start params after setupRuntimePlan', () async {
      final applied = await manager.setupRuntimePlan(
        const EngineRuntimePlanRequest(
          patchConfig: ClashConfig(),
        ),
        coldStartPatchConfig: const ClashConfig(
          tun: Tun(enable: false),
        ),
      );

      expect(applied, isNotNull);
      expect(mihomoAdapter.persistColdStartCalls, 1);
      expect(mihomoAdapter.lastPersistedSetupParams, isNotNull);
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

      expect(updated, isTrue);
      expect(mihomoAdapter.updateConfigCalls, 1);
      expect(mihomoAdapter.persistColdStartCalls, 1);
      expect(mihomoAdapter.lastPersistedSetupParams, isNotNull);
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
  });
}

class _FakeEngineAdapter implements EngineAdapter {
  DateTime? runtimeStartTime;
  bool isInitializedValue = true;
  String setupRuntimePlanMessage = '';
  int applyPendingUpdateCalls = 0;
  int initializeCalls = 0;
  int setupRuntimePlanCalls = 0;
  int startCalls = 0;
  int updateConfigCalls = 0;
  int persistColdStartCalls = 0;
  SetupParams? lastPersistedSetupParams;

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
    return '';
  }

  @override
  Future<bool> start({String? notificationTitle}) async {
    startCalls++;
    return true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<DateTime?> readStartTime() async => runtimeStartTime;

  @override
  Future<void> persistColdStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  }) async {
    persistColdStartCalls++;
    lastPersistedSetupParams = setupParams;
  }
}
