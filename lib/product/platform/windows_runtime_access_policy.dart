import 'package:flutter/foundation.dart';

import '../../enum/enum.dart';
import '../../models/models.dart';
import '../runtime/engine_manager.dart';
import '../runtime/windows_mihomo_runtime.dart';
import 'desktop_platform_services.dart';

class WindowsRuntimeAccessPolicy extends DesktopRuntimeAccessPolicy {
  WindowsRuntimeAccessPolicy({WindowsMihomoRuntime? runtime})
      : runtime = runtime ?? windowsMihomoRuntime;

  final WindowsMihomoRuntime runtime;

  @override
  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) async {
    if (requestedTunEnable) {
      final helper = await runtime.checkAvailability();
      if (!helper.isSuccess) {
        throw StateError(
            'Системная служба Windows недоступна для TUN. ${helper.message}');
      }
    }
    if (runtime.preferService != requestedTunEnable ||
        (requestedTunEnable && !runtime.isActive)) {
      runtime.preferService = requestedTunEnable;
      onResolvedTunEnable(requestedTunEnable);
      await onAuthorizeRestart();
      // Restart applies the configuration to the new owner. Discard the stale
      // outer plan, as Android does after a change in runtime privileges.
      return ResolvedTunAccess.abort(enableTun: requestedTunEnable);
    }
    onResolvedTunEnable(requestedTunEnable);
    return ResolvedTunAccess.proceed(enableTun: requestedTunEnable);
  }

  // Mihomo owns its Windows TUN listener. The engine starts/stops that listener
  // before these platform hooks, so no second VPN lifecycle exists here.
  @override
  Future<bool> startVpn({required AccessControl accessControl}) async => true;

  @override
  Future<void> stopVpn() async {}
}
