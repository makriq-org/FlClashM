import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/services.dart';

import 'interface.dart';

/// Android-only bridge to the `com.follow.clashx/service` AIDL service living
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

  final MethodChannel _channel = const MethodChannel('com.follow.clashx/service');
  Completer<bool> _initCompleter = Completer<bool>();

  static const int _maxCrashRetries = 5;
  int _crashCount = 0;
  DateTime? _lastCrashTime;

  Future<void> _init() async {
    try {
      await _channel.invokeMethod<String>('init')
          .timeout(const Duration(seconds: 15));
      _crashCount = 0;
      if (!_initCompleter.isCompleted) _initCompleter.complete(true);
    } catch (e) {
      commonPrint.log('ClashLib init failed: $e');
      if (!_initCompleter.isCompleted) _initCompleter.complete(false);
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
      if (!_initCompleter.isCompleted) _initCompleter.complete(false);
      return;
    }

    final delayMs = 1000 * (1 << (_crashCount - 1)).clamp(1, 16);
    commonPrint.log(
      'service crash #$_crashCount/$_maxCrashRetries, '
      'retrying in ${delayMs}ms',
    );
    await Future.delayed(Duration(milliseconds: delayMs));
    if (_initCompleter.isCompleted) _initCompleter = Completer<bool>();
    unawaited(_init());
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'event':
        final raw = call.arguments as String?;
        if (raw == null || raw.isEmpty) return null;
        try {
          handleResult(ActionResult.fromJson(json.decode(raw)));
        } catch (e) {
          commonPrint.log('event parse err: $e raw=$raw');
        }
        return null;
      case 'crash':
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
  Future<bool> preload() => _initCompleter.future;

  @override
  Future<bool> destroy() async {
    try {
      await _channel.invokeMethod<bool>('shutdown');
    } catch (_) {}
    return true;
  }

  @override
  void reStart() {
    _crashCount = 0;
    if (_initCompleter.isCompleted) _initCompleter = Completer<bool>();
    unawaited(_init());
  }

  void reconnectIfNeeded() {
    if (_crashCount <= _maxCrashRetries && _initCompleter.isCompleted) return;
    _crashCount = 0;
    if (_initCompleter.isCompleted) _initCompleter = Completer<bool>();
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
            commonPrint.log('_failPendingCompleter: method=$method reason=$reason');
            completer.complete(null);
          }
        }
      }
    } catch (e) {
      commonPrint.log('_failPendingCompleter parse error: $e reason=$reason');
    }
  }

  // --- fork-specific straight-through methods (native returns direct result) --

  @override
  Future<String> getAndroidVpnOptions() async =>
      (await _channel.invokeMethod<String>('getAndroidVpnOptions')) ?? '';

  @override
  Future<bool> updateDns(String value) async {
    await _channel.invokeMethod('updateDns', value);
    return true;
  }

  @override
  Future<DateTime?> getRunTime() async {
    final rt = await _channel.invokeMethod('getRunTime');
    final ms = (rt is int) ? rt : int.tryParse('$rt');
    if (ms == null || ms == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<String> getCurrentProfileName() async =>
      (await _channel.invokeMethod<String>('getCurrentProfileName')) ?? '';

  // --- VPN lifecycle --------------------------------------------------------

  /// Tells the `:remote` service to bring the TUN tunnel up using the current
  /// Go-provided `AndroidVpnOptions`, merged with UI access control settings.
  Future<int> startVpn() async {
    final optionsRaw = await getAndroidVpnOptions();
    final merged = _mergeAccessControl(optionsRaw);
    final res = await _channel.invokeMethod('start', {'data': merged});
    return (res is int) ? res : int.tryParse('$res') ?? 0;
  }

  String _mergeAccessControl(String optionsJson) {
    if (optionsJson.isEmpty) return optionsJson;
    try {
      final map = json.decode(optionsJson) as Map<String, dynamic>;
      final ac = globalState.config.vpnProps.accessControl;
      if (ac.enable) {
        map['accessControl'] = {
          'mode': ac.mode.name,
          'acceptList': ac.acceptList,
          'rejectList': ac.rejectList,
        };
      }
      return json.encode(map);
    } catch (_) {
      return optionsJson;
    }
  }

  Future<bool> stopVpn() async {
    await _channel.invokeMethod('stop');
    return true;
  }

  /// One-shot start: atomically `initClash` + `setupConfig` + foreground
  /// service bring-up on the remote side. Returns an error string (empty on
  /// success) matching the legacy Dart API.
  Future<String> quickStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  }) async {
    final res = await _channel.invokeMethod<String>('quickStart', <String, String>{
      'init': json.encode(initParams),
      'params': json.encode(setupParams),
      'state': json.encode(state),
    });
    return res ?? '';
  }

  /// Push foreground-notification params (title/server/content) so the
  /// :remote service can render the sticky notification without having to
  /// call back into Dart.
  Future<void> updateNotificationParams({
    required String title,
    String server = '',
    bool onlyStatisticsProxy = false,
  }) async {
    await _channel.invokeMethod('updateNotificationParams', json.encode({
      'title': title,
      'stopText': server,
      'onlyStatisticsProxy': onlyStatisticsProxy,
    }));
  }

  /// Persist quickStart-equivalent params so tile/widget/Always-on can
  /// cold-start without Flutter via FlVpnService.coldStart().
  Future<void> saveParamsForColdStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  }) async {
    await _channel.invokeMethod('saveParams', <String, String>{
      'init': json.encode(initParams),
      'params': json.encode(setupParams),
      'state': json.encode(state),
    });
  }
}

ClashLib? get clashLib => Platform.isAndroid ? ClashLib() : null;
