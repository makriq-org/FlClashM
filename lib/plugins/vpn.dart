import 'dart:async';
import 'dart:io';

import 'package:flclashm/clash/clash.dart';
import 'package:flclashm/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Legacy interface kept for call-sites that registered a DNS listener under
/// the old architecture. DNS updates are now applied directly by the `:remote`
/// process via its `NetworkObserveModule`, so listeners here never fire.
abstract mixin class VpnListener {
  void onDnsChanged(String dns) {}
}

/// Thin Android VPN/service bridge. Product policy lives under
/// `lib/product/android/**`; this shim only forwards calls to ClashLib/native.
class Vpn {
  factory Vpn() => _instance ??= Vpn._();
  static Vpn? _instance;

  Vpn._();

  Future<void> updateNotification({required String title}) async {
    try {
      commonPrint.log(
        '[Vpn] updateNotification: title="$title" clashLib=${clashLib != null}',
      );
      await clashLib?.updateNotificationParams(title: title);
    } catch (e) {
      commonPrint.log('[Vpn] updateNotification FAILED: $e');
    }
  }

  /// Restore-pending: Kotlin side needs a matching method on the service
  /// channel. Kept as a best-effort call so Dart call-sites don't error.
  Future<bool?> showSubscriptionNotification({
    required String title,
    required String message,
    required String actionLabel,
    required String actionUrl,
  }) async {
    try {
      return await const MethodChannelShim().invoke<bool>(
        'showSubscriptionNotification',
        <String, String>{
          'title': title,
          'message': message,
          'actionLabel': actionLabel,
          'actionUrl': actionUrl,
        },
      );
    } catch (e) {
      commonPrint.log('showSubscriptionNotification (not wired): $e');
      return false;
    }
  }

  Future<bool> start({String? optionsJson}) async {
    final rt = await clashLib?.startVpn(optionsJson: optionsJson) ?? 0;
    return rt != 0;
  }

  Future<bool> stop() async {
    await clashLib?.stopVpn();
    return true;
  }

  final ObserverList<VpnListener> _listeners = ObserverList<VpnListener>();
  FutureOr<String> Function()? handleGetStartForegroundParams;

  void addListener(VpnListener listener) => _listeners.add(listener);
  void removeListener(VpnListener listener) => _listeners.remove(listener);
}

/// Thin wrapper to forward untyped invocations on the service channel — avoids
/// leaking a direct MethodChannel import from subscription_notification_service.
class MethodChannelShim {
  const MethodChannelShim();
  Future<T?> invoke<T>(String method, dynamic arguments) async {
    const channel = MethodChannel('com.makriq.flclash/service');
    return channel.invokeMethod<T>(method, arguments);
  }
}

Vpn? get vpn => Platform.isAndroid ? Vpn() : null;
