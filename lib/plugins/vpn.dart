import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:io';


/// Compatibility presentation facade; Go owns VPN and subscription policy.
class Vpn {
  Future<void> updateNotification({required String title}) async {
    await const MethodChannel('com.makriq.flclash/service').invokeMethod('updateNotificationParams', jsonEncode({'title':title}));
  }
}

Vpn? get vpn => Platform.isAndroid ? Vpn() : null;
