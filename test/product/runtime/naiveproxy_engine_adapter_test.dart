import 'dart:io';
import 'dart:typed_data';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flclashx/product/runtime/naiveproxy_engine_adapter.dart';
import 'package:flclashx/product/runtime/naiveproxy_release.dart';
import 'package:flclashx/product/runtime/runtime_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NaiveProxyEngineAdapter', () {
    late _FakeNaiveProxyCoreBridge core;
    late _FakeNaiveProxyLifecycleBridge lifecycle;
    late _FakeNaiveProxyPlatformBridge platform;
    late _FakeNaiveProxyProcessBridge process;
    late _FakeNaiveProxyBinaryBridge binary;
    late Directory tempDir;
    late NaiveProxyInstallLayout layout;

    NaiveProxyEngineAdapter buildAdapter({
      AccessControl? accessControl,
      WaitForNaiveProxyListenerCallback? waitForListener,
    }) =>
        NaiveProxyEngineAdapter(
          core: core,
          lifecycle: lifecycle,
          platform: platform,
          process: process,
          binary: binary,
          waitForListener: waitForListener ?? (_) async {},
          readAccessControl: () => accessControl ?? const AccessControl(),
        );

    setUp(() async {
      core = _FakeNaiveProxyCoreBridge();
      lifecycle = _FakeNaiveProxyLifecycleBridge();
      platform = _FakeNaiveProxyPlatformBridge();
      process = _FakeNaiveProxyProcessBridge();
      tempDir = await Directory.systemTemp.createTemp('flclashm-naiveproxy-');
      layout = NaiveProxyInstallLayout(
        abi: 'arm64-v8a',
        runtimeDirectoryPath: tempDir.path,
        executablePath: '${tempDir.path}/naiveproxy',
        pendingPath: '${tempDir.path}/naiveproxy.pending',
        rollbackPath: '${tempDir.path}/naiveproxy.rollback',
        configPath: '${tempDir.path}/config.json',
        versionPath: '${tempDir.path}/bundled.version',
        pendingVersionPath: '${tempDir.path}/bundled.pending.version',
        bundledAssetPath:
            'assets/runtimes/naiveproxy/android/arm64-v8a/libnaive.so',
      );
      binary = _FakeNaiveProxyBinaryBridge(layout: layout);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('starts process, bridge listener and VPN with access-control handoff',
        () async {
      final adapter = buildAdapter(
        accessControl: const AccessControl(
          enable: true,
          rejectList: ['com.example.blocked'],
        ),
      );

      final started = await adapter.start(notificationTitle: 'Foreground');

      expect(started, isTrue);
      expect(process.startCalls, 1);
      expect(core.startListenerCalls, 1);
      expect(platform.startVpnCalls, 1);
      expect(platform.lastStartAccessControl?.rejectList, [
        'com.example.blocked',
      ]);
    });

    test('skips VPN start when bridge runtime is already attached', () async {
      lifecycle.bridgeStartTime = DateTime(2026, 5, 6, 7, 8, 9);
      final adapter = buildAdapter();

      final started = await adapter.start();

      expect(started, isTrue);
      expect(process.startCalls, 1);
      expect(core.startListenerCalls, 1);
      expect(platform.startVpnCalls, 0);
    });

    test('rolls back process, listener and VPN when VPN start returns false',
        () async {
      platform.startVpnResult = false;
      final adapter = buildAdapter();

      final started = await adapter.start();

      expect(started, isFalse);
      expect(core.stopListenerCalls, 1);
      expect(platform.stopVpnCalls, 1);
      expect(process.stopCalls, 1);
    });

    test('writes config.json and restarts process on live runtime plan update',
        () async {
      process.processStartTime = DateTime(2026, 5, 6, 7, 8, 9);
      final adapter = buildAdapter();
      const runtimePlan = RuntimePlan(
        config: {},
        selectedMap: {},
        testUrl: 'https://example.com',
        runtime: RuntimeSelection(engine: RuntimeId.naiveproxy),
        files: {
          naiveProxyRuntimeArtifactConfigPath:
              '{"listen":"socks://127.0.0.1:7891","proxy":"https://example.com"}',
        },
        metadata: null,
      );

      final message = await adapter.setupRuntimePlan(runtimePlan);

      expect(message, isEmpty);
      expect(File(layout.configPath).existsSync(), isTrue);
      expect(process.stopCalls, 1);
      expect(process.startCalls, 1);
      expect(core.setupRuntimePlanCalls, 1);
    });

    test('restores previous config and process when bridge handoff fails',
        () async {
      process.processStartTime = DateTime(2026, 5, 6, 7, 8, 9);
      core.setupRuntimePlanMessage = 'bridge update failed';
      await File(layout.configPath).writeAsString(
        '{"listen":"socks://127.0.0.1:7891","proxy":"https://old.example"}',
      );
      final adapter = buildAdapter();
      const runtimePlan = RuntimePlan(
        config: {},
        selectedMap: {},
        testUrl: 'https://example.com',
        runtime: RuntimeSelection(engine: RuntimeId.naiveproxy),
        files: {
          naiveProxyRuntimeArtifactConfigPath:
              '{"listen":"socks://127.0.0.1:7891","proxy":"https://new.example"}',
        },
        metadata: null,
      );

      final message = await adapter.setupRuntimePlan(runtimePlan);

      expect(message, contains('bridge update failed'));
      expect(
        await File(layout.configPath).readAsString(),
        '{"listen":"socks://127.0.0.1:7891","proxy":"https://old.example"}',
      );
      expect(process.stopCalls, 2);
      expect(process.startCalls, 2);
      expect(core.setupRuntimePlanCalls, 1);
      expect(process.processStartTime, isNotNull);
    });

    test('installs and swaps bundled binaries through pending activation',
        () async {
      final adapter = buildAdapter();
      final active = File(layout.executablePath);
      final pending = File(layout.pendingPath);

      await adapter.applyPendingUpdate();
      expect(await active.readAsString(), 'bundled-binary');

      await active.writeAsString('old-binary');
      await pending.writeAsString('new-binary');
      await File(layout.pendingVersionPath).writeAsString('external-tag');

      await adapter.applyPendingUpdate();

      expect(await active.readAsString(), 'new-binary');
      expect(pending.existsSync(), isFalse);
      expect(await File(layout.versionPath).readAsString(), 'external-tag');
    });

    test('clears cold-start state instead of saving quick-start params',
        () async {
      final adapter = buildAdapter();

      await adapter.persistColdStart(
        initParams: const InitParams(homeDir: '/tmp/flclashm', version: 1),
        setupParams: const SetupParams(
          config: {},
          selectedMap: {},
          testUrl: 'https://example.com',
        ),
        state: const CoreState(
          vpnProps: VpnProps(),
          onlyStatisticsProxy: false,
          currentProfileName: '',
        ),
      );

      expect(lifecycle.clearColdStartCalls, 1);
    });
  });
}

class _FakeNaiveProxyCoreBridge implements NaiveProxyCoreBridge {
  bool isInitializedValue = false;
  int startListenerCalls = 0;
  int stopListenerCalls = 0;
  int setupRuntimePlanCalls = 0;
  String setupRuntimePlanMessage = '';

  @override
  Future<void> shutdown() async {}

  @override
  Future<bool> isInitialized() async => isInitializedValue;

  @override
  Future<void> initialize({
    required InitParams initParams,
    required CoreState state,
  }) async {
    isInitializedValue = true;
  }

  @override
  Future<String> setupRuntimePlan(RuntimePlan runtimePlan) async {
    setupRuntimePlanCalls++;
    return setupRuntimePlanMessage;
  }

  @override
  Future<String> updateRuntimeConfig(UpdateParams updateParams) async => '';

  @override
  Future<void> startListener() async {
    startListenerCalls++;
  }

  @override
  Future<void> stopListener() async {
    stopListenerCalls++;
  }
}

class _FakeNaiveProxyLifecycleBridge implements NaiveProxyLifecycleBridge {
  DateTime? bridgeStartTime;
  int restartCalls = 0;
  int clearColdStartCalls = 0;

  @override
  Future<void> restartRuntime() async {
    restartCalls++;
  }

  @override
  Future<DateTime?> readBridgeStartTime() async => bridgeStartTime;

  @override
  Future<void> clearColdStartState() async {
    clearColdStartCalls++;
  }
}

class _FakeNaiveProxyPlatformBridge implements NaiveProxyPlatformBridge {
  Error? pushTitleError;
  bool startVpnResult = true;
  int startVpnCalls = 0;
  int stopVpnCalls = 0;
  AccessControl? lastStartAccessControl;

  @override
  Future<void> pushForegroundNotificationTitle(String title) async {
    if (pushTitleError != null) {
      throw pushTitleError!;
    }
  }

  @override
  Future<bool> startVpn({required AccessControl accessControl}) async {
    startVpnCalls++;
    lastStartAccessControl = accessControl;
    return startVpnResult;
  }

  @override
  Future<void> stopVpn() async {
    stopVpnCalls++;
  }
}

class _FakeNaiveProxyProcessBridge implements NaiveProxyProcessBridge {
  DateTime? processStartTime = DateTime(2026, 1, 2, 3, 4, 5);
  bool startProcessResult = true;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> startProcess({
    required String executablePath,
    required String workingDirectory,
  }) async {
    startCalls++;
    if (startProcessResult) {
      processStartTime ??= DateTime(2026, 1, 2, 3, 4, 5);
    }
    return startProcessResult;
  }

  @override
  Future<void> stopProcess() async {
    stopCalls++;
    processStartTime = null;
  }

  @override
  Future<DateTime?> readProcessStartTime() async => processStartTime;
}

class _FakeNaiveProxyBinaryBridge implements NaiveProxyBinaryBridge {
  _FakeNaiveProxyBinaryBridge({
    required this.layout,
  });

  final NaiveProxyInstallLayout layout;

  @override
  String get bundledReleaseTag => naiveProxyPinnedReleaseTag;

  @override
  Future<Uint8List> loadBundledBinary(String assetPath) async =>
      Uint8List.fromList('bundled-binary'.codeUnits);

  @override
  Future<NaiveProxyInstallLayout> resolveInstallLayout() async => layout;
}
