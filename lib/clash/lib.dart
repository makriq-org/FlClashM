import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/product/backend/backend_connection.dart';
import 'package:flutter/services.dart';

import '../core/event.dart';

/// Android-only bridge to the `com.makriq.flclash/service` AIDL service living
/// in the `:remote` process. Replaces the old FFI + dart-port / service-isolate
/// architecture: every call now goes through a MethodChannel and is forwarded
/// across AIDL to the Go core.
class ClashLib  {
  factory ClashLib() => _instance ??= ClashLib._internal();
  static ClashLib? _instance;

  ClashLib._internal() {
    _channel.setMethodCallHandler(_onMethodCall);
    unawaited(_init());
  }

  final MethodChannel _channel =
      const MethodChannel('com.makriq.flclash/service');
  final _backendEvents = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  Stream<Map<String, dynamic>> get backendEvents => _backendEvents.stream;
  // Fires after the binding is re-established, e.g. when :remote was
  // replaced; events emitted before Dart re-registered must be resynced.
  final _backendReconnects = StreamController<void>.broadcast();
  Stream<void> get backendReconnects => _backendReconnects.stream;

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

  late final _connection = BackendConnection(
    connect: _connect,
    onReconnected: () => _backendReconnects.add(null),
  );
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
          for (final event in coreEventsFromData(message)) {
            coreEventManager.sendEvent(event);
          }
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

  Future<bool> preload() => _crashCount > _maxCrashRetries
      ? Future.value(false)
      : _connection.ensure();

  Future<bool> destroy() async {
    _connection.invalidate();
    try {
      await _channel.invokeMethod<bool>('shutdown');
    } catch (_) {}
    // The next request establishes a new binding and event listener.
    _crashCount = 0;
    return true;
  }

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

  // :remote rejects the legacy `shutdown` action; unbinding is the only
  // teardown the UI owns.
  Future<bool> shutdown() => destroy();

  Future<String> getAppliedAndroidVpnOptions()=>readAppliedVpnOptions();
  Future<String> readAppliedVpnOptions() async => await _channel.invokeMethod<String>('getAppliedAndroidVpnOptions') ?? '';
  Future<dynamic> invokeAction(String method, Object? data) async {
    if (!await preload()) throw StateError('Android backend unavailable');
    final raw = await _channel.invokeMethod<String>('invokeAction', jsonEncode({
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'method': method, 'data': data,
    }));
    if (raw == null) throw StateError('No response for $method');
    final response = jsonDecode(raw) as Map;
    if (response['code'] != 0) throw StateError('${response['data']}');
    return response['data'];
  }
}
ClashLib? get clashLib => Platform.isAndroid ? ClashLib() : null;
