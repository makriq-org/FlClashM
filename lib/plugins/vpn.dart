import 'dart:async';
import 'dart:io';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Legacy interface kept for call-sites that registered a DNS listener under
/// the old architecture. DNS updates are now applied directly by the `:remote`
/// process via its `NetworkObserveModule`, so listeners here never fire.
abstract mixin class VpnListener {
  void onDnsChanged(String dns) {}
}

/// Compatibility shim for UI code that still reads/writes notification state
/// through the old `vpn` singleton. All transport now goes through [ClashLib]
/// on the `com.follow.clashx/service` channel; this class keeps the caches
/// needed to render the sticky notification title via
/// [ClashLib.updateNotificationParams].
class Vpn {
  factory Vpn() => _instance ??= Vpn._();
  static Vpn? _instance;

  Vpn._();

  String _cachedServerName = '';
  String _cachedProfileName = 'FlClashX';
  String _cachedServiceName = '';

  String get cachedServerName => _cachedServerName;
  String get cachedProfileName => _cachedProfileName;
  String get cachedServiceName => _cachedServiceName;

  void updateServerName(String serverName) {
    _cachedServerName = serverName;
    _pushNotification();
  }

  void updateProfileInfo({
    required String profileName,
    required String serviceName,
  }) {
    _cachedProfileName = profileName;
    _cachedServiceName = serviceName;
    _pushNotification();
  }

  Future<void> _pushNotification() async {
    try {
      final displayName = _cachedServiceName.isNotEmpty
          ? _cachedServiceName
          : _cachedProfileName;
      final title = _cachedServerName.isNotEmpty
          ? '$displayName / $_cachedServerName'
          : displayName;
      commonPrint.log('[Vpn] pushNotification: title="$title" server="$_cachedServiceName" clashLib=${clashLib != null}');
      await clashLib?.updateNotificationParams(
        title: title,
        server: _cachedServiceName,
      );
    } catch (e) {
      commonPrint.log('[Vpn] pushNotification FAILED: $e');
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

  Future<bool> start(String optionsJson) async {
    final rt = await clashLib?.startVpn() ?? 0;
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
    const channel = MethodChannel('com.follow.clashx/service');
    return channel.invokeMethod<T>(method, arguments);
  }
}

Vpn? get vpn => Platform.isAndroid ? Vpn() : null;
