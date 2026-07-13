import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/built_in_proxy_supervisor.dart';
import 'package:flclashx/product/runtime/built_in_proxy_types.dart';
import 'package:flclashx/product/runtime/mihomo_engine_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MihomoEngineAdapter', () {
    late _FakeMihomoCoreBridge core;
    late _FakeMihomoLifecycleBridge lifecycle;
    late _FakeMihomoPlatformBridge platform;
    late _FakeBuiltInProxySupervisor builtInProxySupervisor;
    late List<String> callOrder;

    MihomoEngineAdapter buildAdapter({
      AccessControl? accessControl,
    }) =>
        MihomoEngineAdapter(
          core: core,
          lifecycle: lifecycle,
          platform: platform,
          builtInProxySupervisor: builtInProxySupervisor,
          readAccessControl: () => accessControl ?? const AccessControl(),
        );

    setUp(() async {
      callOrder = [];
      core = _FakeMihomoCoreBridge()..callOrder = callOrder;
      lifecycle = _FakeMihomoLifecycleBridge();
      platform = _FakeMihomoPlatformBridge();
      builtInProxySupervisor = _FakeBuiltInProxySupervisor()
        ..callOrder = callOrder;
    });

    test('starts even when notification title handoff fails', () async {
      platform.pushTitleError = StateError('notification bridge failed');
      final adapter = buildAdapter(
        accessControl: const AccessControl(
          enable: true,
          rejectList: ['com.example.blocked'],
        ),
      );

      final started = await adapter.start(notificationTitle: 'Foreground');

      expect(started, isTrue);
      expect(core.startListenerCalls, 1);
      expect(platform.lastStartAccessControl, isNotNull);
      expect(platform.lastStartAccessControl?.rejectList, [
        'com.example.blocked',
      ]);
    });

    test('skips VPN start when runtime is already attached', () async {
      lifecycle.runtimeStartTime = DateTime(2026, 1, 2, 3, 4, 5);
      final adapter = buildAdapter();

      final started = await adapter.start();

      expect(started, isTrue);
      expect(core.startListenerCalls, 1);
      expect(platform.lastStartAccessControl, isNull);
      expect(platform.stopVpnCalls, 0);
      expect(core.stopListenerCalls, 0);
    });

    test('rolls back listener and VPN when VPN start returns false', () async {
      platform.startVpnResult = false;
      final adapter = buildAdapter();

      final started = await adapter.start();

      expect(started, isFalse);
      expect(core.startListenerCalls, 1);
      expect(core.stopListenerCalls, 1);
      expect(platform.stopVpnCalls, 1);
    });

    test('throws when failed start cannot clean up listener rollback',
        () async {
      platform.startVpnResult = false;
      core.stopListenerError = StateError('listener rollback failed');
      final adapter = buildAdapter();

      await expectLater(
        adapter.start,
        throwsA(isA<StateError>()),
      );

      expect(core.startListenerCalls, 1);
      expect(core.stopListenerCalls, 1);
      expect(platform.stopVpnCalls, 1);
    });

    test('rolls back listener and VPN when VPN start throws', () async {
      platform.startVpnError = StateError('vpn start failed');
      final adapter = buildAdapter();

      await expectLater(
        adapter.start,
        throwsA(isA<StateError>()),
      );

      expect(core.stopListenerCalls, 1);
      expect(platform.stopVpnCalls, 1);
    });

    test('stops VPN even when listener stop fails', () async {
      core.stopListenerError = StateError('listener stop failed');
      final adapter = buildAdapter();

      await expectLater(
        adapter.stop,
        throwsA(isA<StateError>()),
      );

      expect(core.stopListenerCalls, 1);
      expect(platform.stopVpnCalls, 1);
    });

    test('restarts runtime even when shutdown before restart fails', () async {
      core
        ..isInitializedValue = true
        ..shutdownError = StateError('shutdown failed');
      final adapter = buildAdapter();

      await adapter.prepareForRestart();

      expect(core.shutdownCalls, 1);
      expect(lifecycle.restartCalls, 1);
    });

    test('starts built-in proxy nodes before core runtime plan setup',
        () async {
      final adapter = buildAdapter();
      const runtimePlan = RuntimePlan(
        config: {},
        selectedMap: {},
        testUrl: 'https://example.com',
        builtInProxyNodes: [
          BuiltInProxyNodePlan(
            nodeId: 'node-a',
            name: 'Node A',
            type: BuiltInProxyType.naiveproxy,
            listenHost: '127.0.0.1',
            listenPort: 35010,
            protocol: BuiltInProxyProtocol.socks5,
            udp: false,
          ),
        ],
        metadata: null,
      );

      final message = await adapter.setupRuntimePlan(runtimePlan);

      expect(message, isEmpty);
      expect(core.setupRuntimePlanCalls, 1);
      expect(builtInProxySupervisor.stageCalls, 1);
      expect(builtInProxySupervisor.commitCalls, 1);
      expect(builtInProxySupervisor.startCalls, 1);
      expect(builtInProxySupervisor.rollbackCalls, 0);
      expect(callOrder, [
        'stageLocalNodes',
        'startLocalNodes',
        'setupCore',
        'commitLocalNodes',
      ]);
    });

    test('rolls staged built-in nodes back when built-in proxy start fails',
        () async {
      builtInProxySupervisor.startResult = false;
      final adapter = buildAdapter();
      const runtimePlan = RuntimePlan(
        config: {},
        selectedMap: {},
        testUrl: 'https://example.com',
        builtInProxyNodes: [
          BuiltInProxyNodePlan(
            nodeId: 'node-a',
            name: 'Node A',
            type: BuiltInProxyType.byedpi,
            listenHost: '127.0.0.1',
            listenPort: 35010,
            protocol: BuiltInProxyProtocol.socks5,
            udp: false,
          ),
        ],
        metadata: null,
      );

      final message = await adapter.setupRuntimePlan(runtimePlan);

      expect(message, contains('Built-in proxy nodes did not start.'));
      expect(core.setupRuntimePlanCalls, 0);
      expect(builtInProxySupervisor.stageCalls, 1);
      expect(builtInProxySupervisor.commitCalls, 0);
      expect(builtInProxySupervisor.startCalls, 1);
      expect(builtInProxySupervisor.rollbackCalls, 1);
      expect(callOrder, [
        'stageLocalNodes',
        'startLocalNodes',
        'rollbackLocalNodes',
      ]);
    });

    test('rolls staged built-in nodes back when core setup fails', () async {
      core.setupRuntimePlanMessage = 'core setup failed';
      final adapter = buildAdapter();
      const runtimePlan = RuntimePlan(
        config: {},
        selectedMap: {},
        testUrl: 'https://example.com',
        builtInProxyNodes: [
          BuiltInProxyNodePlan(
            nodeId: 'node-a',
            name: 'Node A',
            type: BuiltInProxyType.naiveproxy,
            listenHost: '127.0.0.1',
            listenPort: 35010,
            protocol: BuiltInProxyProtocol.socks5,
            udp: false,
          ),
        ],
        metadata: null,
      );

      final message = await adapter.setupRuntimePlan(runtimePlan);

      expect(message, contains('core setup failed'));
      expect(builtInProxySupervisor.stageCalls, 1);
      expect(builtInProxySupervisor.startCalls, 1);
      expect(builtInProxySupervisor.stopRuntimePlanCalls, 1);
      expect(builtInProxySupervisor.commitCalls, 0);
      expect(builtInProxySupervisor.rollbackCalls, 1);
      expect(callOrder, [
        'stageLocalNodes',
        'startLocalNodes',
        'setupCore',
        'stopStartedLocalNodes',
        'rollbackLocalNodes',
      ]);
    });

    test('skips built-in proxy supervisor for empty runtime plans', () async {
      final adapter = buildAdapter();

      final message = await adapter.setupRuntimePlan(
        const RuntimePlan.empty(
          selectedMap: {},
          testUrl: 'https://example.com',
        ),
      );

      expect(message, isEmpty);
      expect(core.setupRuntimePlanCalls, 1);
      expect(builtInProxySupervisor.stageCalls, 0);
      expect(builtInProxySupervisor.startCalls, 0);
      expect(builtInProxySupervisor.commitCalls, 0);
      expect(builtInProxySupervisor.rollbackCalls, 0);
    });

    test('keeps supervisor path for empty runtime plans after prior nodes',
        () async {
      builtInProxySupervisor.hasCommittedRuntimePlanValue = true;
      final adapter = buildAdapter();

      final message = await adapter.setupRuntimePlan(
        const RuntimePlan.empty(
          selectedMap: {},
          testUrl: 'https://example.com',
        ),
      );

      expect(message, isEmpty);
      expect(core.setupRuntimePlanCalls, 1);
      expect(builtInProxySupervisor.stageCalls, 1);
      expect(builtInProxySupervisor.startCalls, 0);
      expect(builtInProxySupervisor.commitCalls, 1);
      expect(callOrder, [
        'stageLocalNodes',
        'setupCore',
        'commitLocalNodes',
      ]);
    });

    test('delegates runtime start time and cold-start persistence', () async {
      lifecycle.runtimeStartTime = DateTime(2026, 4, 5, 6, 7, 8);
      final adapter = buildAdapter();

      final startTime = await adapter.readStartTime();
      await adapter.persistColdStart(
        initParams: const InitParams(homeDir: '/tmp/flclashm', version: 1),
        runtimePlan: const RuntimePlan.empty(
          selectedMap: {},
          testUrl: 'https://example.com',
        ),
        state: const CoreState(
          vpnProps: VpnProps(),
          onlyStatisticsProxy: false,
          currentProfileName: '',
        ),
      );

      expect(startTime, lifecycle.runtimeStartTime);
      expect(lifecycle.persistColdStartCalls, 1);
      expect(lifecycle.lastPersistedSetupParams, isNotNull);
      expect(builtInProxySupervisor.persistColdStartCalls, 1);
    });
  });
}

class _FakeBuiltInProxySupervisor implements BuiltInProxySupervisor {
  int stageCalls = 0;
  int commitCalls = 0;
  int rollbackCalls = 0;
  int startCalls = 0;
  int stopRuntimePlanCalls = 0;
  int persistColdStartCalls = 0;
  bool startResult = true;
  bool hasCommittedRuntimePlanValue = false;
  List<BuiltInProxyNodePlan> startRuntimePlanStartedPlans = const [];
  List<BuiltInProxyNodePlan> lastStoppedRuntimePlan = const [];
  List<String>? callOrder;

  @override
  bool get hasCommittedRuntimePlan => hasCommittedRuntimePlanValue;

  @override
  Future<void> prepareForRestart() async {}

  @override
  Future<String> stageRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    stageCalls++;
    callOrder?.add('stageLocalNodes');
    return '';
  }

  @override
  Future<String> rollbackStagedRuntimePlan() async {
    rollbackCalls++;
    callOrder?.add('rollbackLocalNodes');
    return '';
  }

  @override
  Future<void> commitStagedRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    commitCalls++;
    hasCommittedRuntimePlanValue = plans.isNotEmpty;
    callOrder?.add('commitLocalNodes');
  }

  @override
  Future<BuiltInProxyRuntimePlanStartResult> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  }) async {
    startCalls++;
    callOrder?.add('startLocalNodes');
    return BuiltInProxyRuntimePlanStartResult(
      isSuccess: startResult,
      startedPlans: startRuntimePlanStartedPlans.isEmpty
          ? List<BuiltInProxyNodePlan>.unmodifiable(plans)
          : startRuntimePlanStartedPlans,
    );
  }

  @override
  Future<bool> start({bool stopAllOnFailure = true}) async =>
      (await startRuntimePlan(
        const [],
        stopAllOnFailure: stopAllOnFailure,
      ))
          .isSuccess;

  @override
  Future<void> stopRuntimePlan(List<BuiltInProxyNodePlan> plans) async {
    stopRuntimePlanCalls++;
    lastStoppedRuntimePlan = List<BuiltInProxyNodePlan>.unmodifiable(plans);
    callOrder?.add('stopStartedLocalNodes');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> persistColdStart() async {
    persistColdStartCalls++;
  }
}

class _FakeMihomoCoreBridge implements MihomoCoreBridge {
  bool isInitializedValue = false;
  Error? shutdownError;
  Error? startListenerError;
  Error? stopListenerError;
  String setupRuntimePlanMessage = '';
  int shutdownCalls = 0;
  int initializeCalls = 0;
  int setupRuntimePlanCalls = 0;
  int startListenerCalls = 0;
  int stopListenerCalls = 0;
  List<String>? callOrder;

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    if (shutdownError != null) {
      throw shutdownError!;
    }
  }

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
    callOrder?.add('setupCore');
    return setupRuntimePlanMessage;
  }

  @override
  Future<String> updateRuntimeConfig(UpdateParams updateParams) async => '';

  @override
  Future<void> startListener() async {
    startListenerCalls++;
    if (startListenerError != null) {
      throw startListenerError!;
    }
  }

  @override
  Future<void> stopListener() async {
    stopListenerCalls++;
    if (stopListenerError != null) {
      throw stopListenerError!;
    }
  }
}

class _FakeMihomoLifecycleBridge implements MihomoLifecycleBridge {
  DateTime? runtimeStartTime;
  int restartCalls = 0;
  int persistColdStartCalls = 0;
  SetupParams? lastPersistedSetupParams;

  @override
  Future<void> restartRuntime() async {
    restartCalls++;
  }

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

class _FakeMihomoPlatformBridge implements MihomoPlatformBridge {
  Error? pushTitleError;
  Error? startVpnError;
  Error? stopVpnError;
  bool startVpnResult = true;
  AccessControl? lastStartAccessControl;
  int stopVpnCalls = 0;

  @override
  Future<void> pushForegroundNotificationTitle(String title) async {
    if (pushTitleError != null) {
      throw pushTitleError!;
    }
  }

  @override
  Future<bool> startVpn({required AccessControl accessControl}) async {
    lastStartAccessControl = accessControl;
    if (startVpnError != null) {
      throw startVpnError!;
    }
    return startVpnResult;
  }

  @override
  Future<void> stopVpn() async {
    stopVpnCalls++;
    if (stopVpnError != null) {
      throw stopVpnError!;
    }
  }
}
