import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../clash/clash.dart';
import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../models/models.dart';
import '../../plugins/app.dart';
import '../../plugins/vpn.dart';
import '../runtime/engine_manager.dart';
import '../runtime/vpn_access_control.dart';

@immutable
class ProfileAccessSnapshot {
  const ProfileAccessSnapshot.available(this.accessControl) : available = true;

  const ProfileAccessSnapshot.unavailable()
      : available = false,
        accessControl = null;

  final bool available;
  final AccessControl? accessControl;
}

abstract interface class RuntimeAccessPlatformBridge {
  bool get isAndroid;

  Future<List<Package>> readPackages();

  Future<ImageProvider?> readPackageIcon(String packageName);

  String mergeVpnOptions(
    String optionsJson, {
    required AccessControl accessControl,
  });

  Future<bool> startVpn({required AccessControl accessControl});

  Future<void> stopVpn();

  /// Reads the immutable options snapshot used to establish the live Android
  /// VPN. An available snapshot with null access control means that the VPN
  /// explicitly has no profile package rule; unavailable means the remote
  /// service could not provide a trustworthy snapshot.
  Future<ProfileAccessSnapshot> readAppliedProfileAccess();

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
    this.appliedOptionsReader,
  });

  final List<String> selfPackageNames;
  final Future<String> Function()? appliedOptionsReader;

  @override
  bool get isAndroid => Platform.isAndroid;

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
    final hardenedAccessControl = enforceSelfPackageBypass(
      accessControl,
      selfPackageNames: selfPackageNames,
    );

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

  @override
  Future<void> stopVpn() async {
    await vpn?.stop();
  }

  @override
  Future<ProfileAccessSnapshot> readAppliedProfileAccess() async {
    final optionsJson = await (appliedOptionsReader?.call() ??
        clashLib?.getAppliedAndroidVpnOptions() ??
        Future.value(''));
    if (optionsJson.isEmpty) {
      return const ProfileAccessSnapshot.unavailable();
    }
    try {
      final options = json.decode(optionsJson) as Map<String, dynamic>;
      final include = _readNullableStringList(options, 'includePackage');
      final exclude = _readNullableStringList(options, 'excludePackage');
      if (include != null && exclude != null) {
        return const ProfileAccessSnapshot.unavailable();
      }
      if (include != null) {
        return ProfileAccessSnapshot.available(
          AccessControl(
            enable: true,
            mode: AccessControlMode.acceptSelected,
            acceptList: include,
          ),
        );
      }
      if (exclude != null) {
        return ProfileAccessSnapshot.available(
          AccessControl(
            enable: true,
            mode: AccessControlMode.rejectSelected,
            rejectList: exclude,
          ),
        );
      }
      return const ProfileAccessSnapshot.available(null);
    } catch (_) {
      return const ProfileAccessSnapshot.unavailable();
    }
  }

  List<String>? _readNullableStringList(
    Map<String, dynamic> options,
    String key,
  ) {
    final value = options[key];
    if (value == null) {
      return null;
    }
    if (value is! List || value.any((item) => item is! String)) {
      throw FormatException('Invalid `$key` in applied VPN options.');
    }
    return List<String>.unmodifiable(value.cast<String>());
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
