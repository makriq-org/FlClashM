import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../../plugins/app.dart';
import '../../plugins/vpn.dart';
import '../runtime/engine_manager.dart';

abstract interface class RuntimeAccessPlatformBridge {
  Future<List<Package>> readPackages();

  Future<ImageProvider?> readPackageIcon(String packageName);

  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  });

  Future<bool> startVpn({required AccessControl accessControl});

  Future<void> stopVpn();

  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  });
}

class AndroidRuntimeAccessPolicy implements RuntimeAccessPlatformBridge {
  const AndroidRuntimeAccessPolicy();

  @override
  Future<List<Package>> readPackages() async => await app?.getPackages() ?? [];

  @override
  Future<ImageProvider?> readPackageIcon(String packageName) =>
      app?.getPackageIcon(packageName) ?? Future.value(null);

  @override
  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  }) {
    if (optionsJson.isEmpty) {
      return optionsJson;
    }

    try {
      return json.encode(
        (json.decode(optionsJson) as Map<String, dynamic>)
          ..remove('accessControl')
          ..addAll(
            accessControl.enable
                ? {
                    'accessControl': {
                      'mode': accessControl.mode.name,
                      'acceptList': accessControl.acceptList,
                      'rejectList': accessControl.rejectList,
                    },
                  }
                : const {},
          ),
      );
    } catch (_) {
      return optionsJson;
    }
  }

  @override
  Future<bool> startVpn({required AccessControl accessControl}) async {
    final optionsJson = await clashLib?.getAndroidVpnOptions() ?? '';
    final mergedOptions = mergeVpnOptions(
      optionsJson,
      accessControl: accessControl,
    );
    return await vpn?.start(optionsJson: mergedOptions) ?? false;
  }

  @override
  Future<void> stopVpn() async {
    await vpn?.stop();
  }

  @override
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
