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
  const AndroidRuntimeAccessPolicy({
    this.selfPackageNames = const [packageName, '$packageName.dev'],
  });

  final List<String> selfPackageNames;

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
    final hardenedAccessControl = _withSelfBypass(accessControl);

    try {
      return json.encode(
        (json.decode(optionsJson) as Map<String, dynamic>)
          ..remove('accessControl')
          ..addAll(
            hardenedAccessControl.enable
                ? {
                    'accessControl': {
                      'mode': hardenedAccessControl.mode.name,
                      'acceptList': hardenedAccessControl.acceptList,
                      'rejectList': hardenedAccessControl.rejectList,
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

  AccessControl _withSelfBypass(AccessControl accessControl) {
    final selfPackages = selfPackageNames
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (selfPackages.isEmpty) {
      return accessControl;
    }

    if (!accessControl.enable) {
      return accessControl.copyWith(
        enable: true,
        mode: AccessControlMode.rejectSelected,
        rejectList: selfPackages.toList(growable: false),
      );
    }

    return switch (accessControl.mode) {
      AccessControlMode.acceptSelected => accessControl.copyWith(
          acceptList: accessControl.acceptList
              .where((name) => !selfPackages.contains(name))
              .toList(growable: false),
        ),
      AccessControlMode.rejectSelected => accessControl.copyWith(
          rejectList: {
            ...accessControl.rejectList,
            ...selfPackages,
          }.toList(growable: false),
        ),
    };
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
