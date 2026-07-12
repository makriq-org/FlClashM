// ignore_for_file: avoid_positional_boolean_parameters

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
import 'package:flclashx/product/runtime/engine_manager.dart';
import 'package:flclashx/product/services/access_control_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRuntimeAccessPlatform implements RuntimeAccessPlatformBridge {
  AccessControl? lastStartAccessControl;
  int stopCalls = 0;
  int resolveCalls = 0;

  @override
  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  }) =>
      optionsJson;

  @override
  Future<bool> startVpn({required AccessControl accessControl}) async {
    lastStartAccessControl = accessControl;
    return true;
  }

  @override
  Future<void> stopVpn() async {
    stopCalls++;
  }

  @override
  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required void Function(bool) onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) async {
    resolveCalls++;
    onResolvedTunEnable(requestedTunEnable);
    return ResolvedTunAccess.proceed(enableTun: requestedTunEnable);
  }
}

void main() {
  group('AccessControlService', () {
    test('passes manual access control to the platform unchanged', () async {
      final platform = _FakeRuntimeAccessPlatform();
      final service = AccessControlService(platform: platform);
      const accessControl = AccessControl(
        enable: true,
        mode: AccessControlMode.rejectSelected,
        rejectList: ['com.example.blocked'],
      );

      final started = await service.startVpn(accessControl: accessControl);
      await service.stopVpn();

      expect(started, isTrue);
      expect(platform.lastStartAccessControl, accessControl);
      expect(platform.stopCalls, 1);
    });

    test('delegates tunnel authorization to the platform', () async {
      final platform = _FakeRuntimeAccessPlatform();
      final service = AccessControlService(platform: platform);
      final resolvedValues = <bool>[];

      final resolved = await service.resolveRuntimeAccess(
        requestedTunEnable: true,
        realTunEnable: false,
        onAuthorizeRestart: () async {},
        onResolvedTunEnable: resolvedValues.add,
      );

      expect(platform.resolveCalls, 1);
      expect(resolved.enableTun, isTrue);
      expect(resolvedValues, [true]);
    });
  });
}
