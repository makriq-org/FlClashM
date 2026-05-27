import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../plugins/vpn.dart';
import '../../product/runtime/product_runtime.dart';
import '../../state.dart';

class AndroidRuntimeAccessPolicy {
  const AndroidRuntimeAccessPolicy();

  String mergeVpnOptions(String optionsJson) {
    if (optionsJson.isEmpty) {
      return optionsJson;
    }

    try {
      final map = json.decode(optionsJson) as Map<String, dynamic>;
      final accessControl = globalState.config.vpnProps.accessControl;
      if (accessControl.enable) {
        map['accessControl'] = {
          'mode': accessControl.mode.name,
          'acceptList': accessControl.acceptList,
          'rejectList': accessControl.rejectList,
        };
      }
      return json.encode(map);
    } catch (_) {
      return optionsJson;
    }
  }

  Future<bool> startVpn() async {
    final optionsJson = await clashLib?.getAndroidVpnOptions() ?? '';
    final mergedOptions = mergeVpnOptions(optionsJson);
    return await vpn?.start(optionsJson: mergedOptions) ?? false;
  }

  Future<void> stopVpn() async {
    await vpn?.stop();
  }

  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  }) async {
    var enableTun = requestedTunEnable;
    if (enableTun != realTunEnable && !realTunEnable) {
      final code = await (authorizeCore ?? system.authorizeCore)();
      switch (code) {
        case AuthorizeCode.success:
          await onAuthorizeRestart();
          return const ResolvedTunAccess.abort();
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          enableTun = false;
          break;
      }
    }

    onResolvedTunEnable(enableTun);
    return ResolvedTunAccess.proceed(enableTun: enableTun);
  }
}
