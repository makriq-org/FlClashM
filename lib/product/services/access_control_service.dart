import 'package:flutter/foundation.dart';

import '../../enum/enum.dart';
import '../../models/models.dart';
import '../android/android_runtime_access_policy.dart';
import '../runtime/engine_manager.dart';

class AccessControlService {
  const AccessControlService({
    this.platform = const AndroidRuntimeAccessPolicy(),
  });

  final RuntimeAccessPlatformBridge platform;

  Future<bool> startVpn({required AccessControl accessControl}) =>
      platform.startVpn(accessControl: accessControl);

  Future<void> stopVpn() => platform.stopVpn();

  Future<ResolvedTunAccess> resolveRuntimeAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) =>
      platform.resolveTunAccess(
        requestedTunEnable: requestedTunEnable,
        realTunEnable: realTunEnable,
        onAuthorizeRestart: onAuthorizeRestart,
        onResolvedTunEnable: onResolvedTunEnable,
        authorizeCore: authorizeCore,
      );
}
