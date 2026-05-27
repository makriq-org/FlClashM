import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/product_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EngineManager', () {
    late _FakeEngineAdapter adapter;
    late EngineManager manager;

    setUp(() {
      adapter = _FakeEngineAdapter();
      manager = EngineManager(
        adapter: adapter,
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
            const RuntimePlan.empty(
          selectedMap: {},
          testUrl: 'https://example.com',
        ),
        applyRuntimePlan: (_) {},
        buildCoreState: () => const CoreState(
          vpnProps: VpnProps(),
          onlyStatisticsProxy: false,
          currentProfileName: '',
        ),
        buildInitParams: () async =>
            const InitParams(homeDir: '/tmp/flclashm', version: 1),
      );
    });

    test('re-attaches through adapter when runtime is already running',
        () async {
      adapter.runtimeStartTime = DateTime(2026, 1, 2, 3, 4, 5);

      await manager.syncStartTime();
      final started = await manager.start();

      expect(started, isTrue);
      expect(adapter.startCalls, 1);
      expect(manager.startTime, adapter.runtimeStartTime);
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
      expect(adapter.persistColdStartCalls, 1);
      expect(adapter.lastPersistedSetupParams, isNotNull);
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
      expect(adapter.updateConfigCalls, 1);
      expect(adapter.persistColdStartCalls, 1);
      expect(adapter.lastPersistedSetupParams, isNotNull);
    });
  });
}

class _FakeEngineAdapter implements EngineAdapter {
  DateTime? runtimeStartTime;
  int startCalls = 0;
  int updateConfigCalls = 0;
  int persistColdStartCalls = 0;
  SetupParams? lastPersistedSetupParams;

  @override
  Future<void> applyPendingUpdate() async {}

  @override
  Future<void> prepareForRestart() async {}

  @override
  Future<bool> isInitialized() async => true;

  @override
  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  }) async {}

  @override
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) async => '';

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
