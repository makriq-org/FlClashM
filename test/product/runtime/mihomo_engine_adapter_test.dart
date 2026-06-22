import 'dart:io';

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
    late _FakeMihomoUpdateBridge update;
    late _FakeBuiltInProxySupervisor builtInProxySupervisor;
    late List<String> callOrder;
    late Directory tempDir;

    MihomoEngineAdapter buildAdapter({
      AccessControl? accessControl,
    }) =>
        MihomoEngineAdapter(
          core: core,
          lifecycle: lifecycle,
          platform: platform,
          update: update,
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
      tempDir = await Directory.systemTemp.createTemp('flclashm-mihomo-');
      update = _FakeMihomoUpdateBridge(
        corePath: '${tempDir.path}/FlClashCore',
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
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

    test('still starts VPN when runtime probe reports an attached runtime',
        () async {
      lifecycle.runtimeStartTime = DateTime(2026, 1, 2, 3, 4, 5);
      final adapter = buildAdapter();

      final started = await adapter.start();

      expect(started, isTrue);
      expect(core.startListenerCalls, 1);
      expect(platform.lastStartAccessControl, isNotNull);
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

    test('stages and commits built-in proxy nodes on runtime plan setup',
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
      await Future<void>.delayed(Duration.zero);

      expect(message, isEmpty);
      expect(core.setupRuntimePlanCalls, 1);
      expect(builtInProxySupervisor.stageCalls, 1);
      expect(builtInProxySupervisor.commitCalls, 1);
      expect(builtInProxySupervisor.startCalls, 1);
      expect(builtInProxySupervisor.rollbackCalls, 0);
      expect(callOrder, [
        'stageLocalNodes',
        'setupCore',
        'commitLocalNodes',
        'startLocalNodes',
      ]);
    });

    test('continues runtime plan setup when built-in proxy start fails',
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
      await Future<void>.delayed(Duration.zero);

      expect(message, isEmpty);
      expect(core.setupRuntimePlanCalls, 1);
      expect(builtInProxySupervisor.stageCalls, 1);
      expect(builtInProxySupervisor.commitCalls, 1);
      expect(builtInProxySupervisor.startCalls, 1);
      expect(builtInProxySupervisor.rollbackCalls, 0);
      expect(callOrder, [
        'stageLocalNodes',
        'setupCore',
        'commitLocalNodes',
        'startLocalNodes',
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
      expect(builtInProxySupervisor.commitCalls, 0);
      expect(builtInProxySupervisor.rollbackCalls, 1);
    });

    test('atomically swaps in a pending core update', () async {
      final adapter = buildAdapter();
      final target = File(update.corePath);
      final pending = File(update.corePendingPath);
      await target.writeAsString('old-core');
      await pending.writeAsString('new-core');

      await adapter.applyPendingUpdate();

      expect(await target.readAsString(), 'new-core');
      expect(pending.existsSync(), isFalse);
      expect(File('${update.corePath}.rollback').existsSync(), isFalse);
      expect(update.setExecutableCalls, 1);
      expect(builtInProxySupervisor.applyPendingUpdateCalls, 1);
    });

    test('restores the previous core when pending activation fails', () async {
      update.setExecutableError = StateError('chmod failed');
      final adapter = buildAdapter();
      final target = File(update.corePath);
      final pending = File(update.corePendingPath);
      await target.writeAsString('old-core');
      await pending.writeAsString('new-core');

      await expectLater(
        adapter.applyPendingUpdate,
        throwsA(isA<StateError>()),
      );

      expect(await target.readAsString(), 'old-core');
      expect(await pending.readAsString(), 'new-core');
      expect(File('${update.corePath}.rollback').existsSync(), isFalse);
      expect(builtInProxySupervisor.applyPendingUpdateCalls, 1);
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
  int applyPendingUpdateCalls = 0;
  int stageCalls = 0;
  int commitCalls = 0;
  int rollbackCalls = 0;
  int startCalls = 0;
  int persistColdStartCalls = 0;
  bool startResult = true;
  List<String>? callOrder;

  @override
  Future<void> applyPendingUpdate() async {
    applyPendingUpdateCalls++;
  }

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
    callOrder?.add('commitLocalNodes');
  }

  @override
  Future<bool> startRuntimePlan(
    List<BuiltInProxyNodePlan> plans, {
    bool stopAllOnFailure = true,
  }) async {
    startCalls++;
    callOrder?.add('startLocalNodes');
    return startResult;
  }

  @override
  Future<bool> start({bool stopAllOnFailure = true}) async =>
      startRuntimePlan(const [], stopAllOnFailure: stopAllOnFailure);

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

class _FakeMihomoUpdateBridge implements MihomoUpdateBridge {
  _FakeMihomoUpdateBridge({
    required this.corePath,
  });

  @override
  final String corePath;

  Error? setExecutableError;
  int setExecutableCalls = 0;

  @override
  String get corePendingPath => '$corePath.pending';

  @override
  bool get supportsExecutableBit => true;

  @override
  Future<void> setExecutable(String path) async {
    setExecutableCalls++;
    if (setExecutableError != null) {
      throw setExecutableError!;
    }
  }
}
