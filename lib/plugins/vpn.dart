import 'dart:io';

import 'package:flclashx/clash/clash.dart';

/// Compatibility presentation facade; Go owns VPN and subscription policy.
class Vpn {
  Future<void> updateNotification({required String title}) async {
    await clashLib?.updateNotificationParams(title: title);
  }
}

Vpn? get vpn => Platform.isAndroid ? Vpn() : null;
