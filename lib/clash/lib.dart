import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/backend/backend_connection.dart';
import 'package:flutter/services.dart';

import 'interface.dart';

/// Android-only bridge to the `com.makriq.flclash/service` AIDL service living
/// in the `:remote` process. Replaces the old FFI + dart-port / service-isolate
/// architecture: every call now goes through a MethodChannel and is forwarded
/// across AIDL to the Go core.
class ClashLib extends ClashHandlerInterface with AndroidClashInterface {
  factory ClashLib() => _instance ??= ClashLib._internal();
  static ClashLib? _instance;

  ClashLib._internal() {
    _channel.setMethodCallHandler(_onMethodCall);
    unawaited(_init());
  }

  final MethodChannel _channel = const MethodChannel(
    'com.makriq.flclash/service',
  );
  final _backendEvents = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  Stream<Map<String, dynamic>> get backendEvents => _backendEvents.stream;

  Future<bool> requestVpnPermission() async =>
      await _channel.invokeMethod<bool>('requestVpnPermission') ?? false;

  Future<Map<String, dynamic>> invokeBackend(
    Map<String, dynamic> request,
  ) async {
    if (!await preload())
      throw StateError('Android backend connection is unavailable');
    final raw = await _channel.invokeMethod<String>(
      'invokeAction',
      jsonEncode({
        'id': request['operationId'],
        'method': 'backend',
        'data': request,
      }),
    );
    if (raw == null || raw.isEmpty) throw StateError('Empty backend response');
    final envelope = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (envelope['code'] != 0) throw StateError('${envelope['data']}');
    return Map<String, dynamic>.from(envelope['data'] as Map);
  }

  late final _connection = BackendConnection(connect: _connect);
  bool get _initInFlight => _connection.connecting;

  static const int _maxCrashRetries = 5;
  int _crashCount = 0;
  DateTime? _lastCrashTime;

  Future<void> _init() async => _connection.ensure().then((_) {});

  Future<bool> _connect() async {
    try {
      await _channel
          .invokeMethod<String>('init')
          .timeout(const Duration(seconds: 15));
      _crashCount = 0;
      return true;
    } catch (e) {
      commonPrint.log('ClashLib init failed: $e');
      return false;
    }
  }

  Future<void> _handleCrashRestart() async {
    final now = DateTime.now();
    if (_lastCrashTime != null &&
        now.difference(_lastCrashTime!).inSeconds > 60) {
      _crashCount = 0;
    }
    _lastCrashTime = now;
    _crashCount++;

    if (_crashCount > _maxCrashRetries) {
      commonPrint.log(
        'service crash loop: $_crashCount crashes, giving up. '
        'Restart the app to retry.',
      );
      return;
    }

    final delayMs = 1000 * (1 << (_crashCount - 1)).clamp(1, 16);
    commonPrint.log(
      'service crash #$_crashCount/$_maxCrashRetries, '
      'retrying in ${delayMs}ms',
    );
    await Future.delayed(Duration(milliseconds: delayMs));
    // A prior _init() may already be running (e.g. another crash arrived mid-
    // init); don't spawn a second concurrent native init.
    if (_initInFlight) {
      commonPrint.log('service crash restart skipped: init already in flight');
      return;
    }
    unawaited(_init());
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'event':
        final raw = call.arguments as String?;
        if (raw == null || raw.isEmpty) return null;
        try {
          final envelope = json.decode(raw) as Map;
          final message = envelope['data'];
          if (message is Map && message['type'] == 'backend') {
            _backendEvents.add(
              Map<String, dynamic>.from(message['data'] as Map),
            );
            return null;
          }
          handleResult(ActionResult.fromJson(json.decode(raw)));
        } catch (e) {
          commonPrint.log('event parse err: $e raw=$raw');
        }
        return null;
      case 'crash':
        _connection.invalidate();
        commonPrint.log('service crash: ${call.arguments}');
        unawaited(_handleCrashRestart());
        return null;
      case 'onStarted':
        return null;
      default:
        return null;
    }
  }

  @override
  Future<bool> preload() => _crashCount > _maxCrashRetries
      ? Future.value(false)
      : _connection.ensure();

  @override
  Future<bool> destroy() async {
    _connection.invalidate();
    try {
      await _channel.invokeMethod<bool>('shutdown');
    } catch (_) {}
    // The next request establishes a new binding and event listener.
    _crashCount = 0;
    return true;
  }

  @override
  void reStart() {
    _connection.invalidate();
    _crashCount = 0;
    unawaited(_init());
  }

  void reconnectIfNeeded() {
    if (_initInFlight || _crashCount > _maxCrashRetries) return;
    // Re-arm the event pipe on foreground entry, even when the old remote
    // process was replaced while this Flutter engine remained alive.
    _crashCount = 0;
    _connection.invalidate();
    unawaited(_init());
  }

  @override
  Future<bool> shutdown() async {
    await super.shutdown();
    return destroy();
  }

  @override
  Future<void> sendMessage(String message) async {
    try {
      final res = await _channel.invokeMethod<String>('invokeAction', message);
      if (res == null || res.isEmpty) {
        _failPendingCompleter(message, 'empty response');
        return;
      }
      try {
        handleResult(ActionResult.fromJson(json.decode(res)));
      } catch (e) {
        commonPrint.log('invokeAction parse err: $e');
        _failPendingCompleter(message, res);
      }
    } catch (e) {
      commonPrint.log('sendMessage channel error: $e');
      _failPendingCompleter(message, '$e');
    }
  }

  void _failPendingCompleter(String message, String reason) {
    try {
      final decoded = json.decode(message);
      if (decoded is Map<String, dynamic>) {
        final id = decoded['id'] as String?;
        final method = decoded['method'] as String?;
        if (id != null) {
          final completer = callbackCompleterMap.remove(id);
          if (completer != null && !completer.isCompleted) {
            commonPrint.log(
              '_failPendingCompleter: method=$method reason=$reason',
            );
            // Complete with the typed default (not null) so a Completer<bool/String/Map>
            // resolves immediately instead of throwing TypeError and hanging to timeout.
            completer.complete(callbackDefaultMap.remove(id));
          }
        }
      }
    } catch (e) {
      commonPrint.log('_failPendingCompleter parse error: $e reason=$reason');
    }
  }

  // --- fork-specific straight-through methods (native returns direct result) --

  @override
  Future<String> getAndroidVpnOptions() async {
    try {
      return (await _channel
              .invokeMethod<String>('getAndroidVpnOptions')
              .timeout(const Duration(seconds: 10))) ??
          '';
    } catch (e) {
      commonPrint.log('getAndroidVpnOptions error: $e');
      return '';
    }
  }

  @override
  Future<String> getAppliedAndroidVpnOptions() async {
    try {
      return (await _channel
              .invokeMethod<String>('getAppliedAndroidVpnOptions')
              .timeout(const Duration(seconds: 10))) ??
          '';
    } catch (e) {
      commonPrint.log('getAppliedAndroidVpnOptions error: $e');
      return '';
    }
  }

  /// null means the tunnel is confirmed stopped. A failed probe (channel
  /// error / timeout) THROWS instead of returning null — callers must be able
  /// to tell "stopped" from "unknown", otherwise a slow bind on cold start
  /// gets treated as "stopped" and actively kills a live VPN.
  @override
  Future<DateTime?> getRunTime() async {
    final rt = await _channel
        .invokeMethod('getRunTime')
        .timeout(const Duration(seconds: 10));
    final ms = (rt is int) ? rt : int.tryParse('$rt');
    if (ms == null || ms == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<String> getCurrentProfileName() async {
    try {
      return (await _channel
              .invokeMethod<String>('getCurrentProfileName')
              .timeout(const Duration(seconds: 10))) ??
          '';
    } catch (e) {
      commonPrint.log('getCurrentProfileName error: $e');
      return '';
    }
  }

  /// Push foreground-notification params (title/server/content) so the
  /// :remote service can render the sticky notification without having to
  /// call back into Dart.
  Future<void> updateNotificationParams({
    required String title,
    String server = '',
    bool onlyStatisticsProxy = false,
  }) async {
    try {
      await _channel
          .invokeMethod(
            'updateNotificationParams',
            json.encode({
              'title': title,
              'stopText': server,
              'onlyStatisticsProxy': onlyStatisticsProxy,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      commonPrint.log('updateNotificationParams error: $e');
    }
  }
}

ClashLib? get clashLib => Platform.isAndroid ? ClashLib() : null;
