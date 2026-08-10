import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../enum/enum.dart';
import '../../models/models.dart';
import '../runtime/engine_manager.dart';

@immutable
class ProfileAccessSnapshot {
  const ProfileAccessSnapshot.available(this.accessControl) : available = true;

  const ProfileAccessSnapshot.unavailable()
      : available = false,
        accessControl = null;

  final bool available;
  final AccessControl? accessControl;
}

/// Platform boundary for TUN and Android package inventory.
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
  Future<ProfileAccessSnapshot> readAppliedProfileAccess();

  Future<ResolvedTunAccess> resolveTunAccess({
    required bool requestedTunEnable,
    required bool realTunEnable,
    required Future<void> Function() onAuthorizeRestart,
    required ValueChanged<bool> onResolvedTunEnable,
    Future<AuthorizeCode> Function()? authorizeCore,
  });
}
