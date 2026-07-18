import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
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

  final MethodChannel _channel =
      const MethodChannel('com.makriq.flclash/service');
  Completer<bool> _initCompleter = Completer<bool>();
  // Guards against launching a second concurrent native `init` while a prior
  // _init() is still awaiting (its completer not yet settled).
  bool _initInFlight = false;

  static const int _maxCrashRetries = 5;
  int _crashCount = 0;
  DateTime? _lastCrashTime;

  Future<void> _init() async {
    _initInFlight = true;
    try {
      await _channel
          .invokeMethod<String>('init')
          .timeout(const Duration(seconds: 15));
      _crashCount = 0;
      if (!_initCompleter.isCompleted) _initCompleter.complete(true);
    } catch (e) {
      commonPrint.log('ClashLib init failed: $e');
      if (!_initCompleter.isCompleted) _initCompleter.complete(false);
    } finally {
      _initInFlight = false;
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
    // A prior _init() may already be running (e.g. another crash arrived mid-
    // init); don't spawn a second concurrent native init.
    if (_initInFlight) {
      commonPrint.log('service crash restart skipped: init already in flight');
      return;
    }
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
    // shutdown unbinds the remote service; re-arm init state so a later preload()/
    // reconnectIfNeeded() forces a fresh bind + event-listener registration instead
    // of reporting "ready" against a dead service.
    _crashCount = 0;
    if (_initCompleter.isCompleted) _initCompleter = Completer<bool>();
    return true;
  }

  @override
  void reStart() {
    _crashCount = 0;
    if (_initCompleter.isCompleted) _initCompleter = Completer<bool>();
    unawaited(_init());
  }

  void reconnectIfNeeded() {
    // An init is already running (completer not yet settled); let it finish
    // rather than spawning a second concurrent native init.
    if (_initInFlight) {
      return;
    }
    // Re-register on EVERY resume (no _initSucceeded short-circuit): the event pipe is
    // registered once per Flutter engine, but a warm app-open after a headless tile
    // start keeps this engine alive while the :remote core it registered against has
    // been recycled (eventListener==nil) — so logs/journal/delays silently stop
    // arriving even though the polled traffic keeps working. Re-invoking init re-binds
    // and re-registers the listener idempotently (Service.bind no-ops if bound;
    // setEventListener swaps the listener under a lock). Still respect the crash budget
    // so a genuine crash-loop doesn't spin.
    if (_crashCount > _maxCrashRetries) {
      return;
    }
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

  @override
  Future<bool> updateDns(String value) async {
    try {
      await _channel
          .invokeMethod('updateDns', value)
          .timeout(const Duration(seconds: 10));
      return true;
    } catch (e) {
      commonPrint.log('updateDns error: $e');
      return false;
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

  // --- VPN lifecycle --------------------------------------------------------

  /// Tells the `:remote` service to bring the TUN tunnel up using the current
  /// Go-provided `AndroidVpnOptions`, merged with UI access control settings.
  Future<int> startVpn({String? optionsJson}) async {
    final payload = optionsJson ?? await getAndroidVpnOptions();
    if (payload.isEmpty) {
      // Probe failed/timed out (e.g. core busy in setupConfig). Starting anyway
      // would bring the tunnel up with default VpnOptions — no routes, no
      // access control (split tunneling silently lost). Fail the start instead.
      // (Access control itself is resolved by the product layer before this
      // call — see resolveVpnAccessControl — so no extra merge happens here.)
      commonPrint.log('startVpn aborted: empty AndroidVpnOptions');
      return 0;
    }
    // Defensive backstop: the native side always replies (even on permission
    // denial -> 0), but never block the start flow indefinitely if it doesn't.
    final res = await _channel
        .invokeMethod('start', {'data': payload})
        .timeout(const Duration(seconds: 60), onTimeout: () => 0);
    return (res is int) ? res : int.tryParse('$res') ?? 0;
  }

  Future<bool> stopVpn() async {
    // The native side resolves the result inside a coroutine that can be
    // cancelled (engine detach) or starved (frozen main dispatcher) — without
    // a timeout this await can hang forever, leaving the UI stuck in
    // "connected" with a frozen runtime. UI-side cleanup must always proceed.
    try {
      await _channel
          .invokeMethod('stop')
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
    } catch (e) {
      commonPrint.log('stopVpn error: $e');
    }
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
    final res = await _channel
        .invokeMethod<String>('quickStart', <String, String>{
          'init': json.encode(initParams),
          'params': json.encode(setupParams),
          'state': json.encode(state),
        })
        .timeout(const Duration(seconds: 60),
            onTimeout: () => 'quickStart timed out');
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
    try {
      await _channel
          .invokeMethod('updateNotificationParams', json.encode({
            'title': title,
            'stopText': server,
            'onlyStatisticsProxy': onlyStatisticsProxy,
          }))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      commonPrint.log('updateNotificationParams error: $e');
    }
  }

  /// Toggle Crashlytics collection. Kotlin persists the flag (SavedParams)
  /// and applies it in both the main and :remote processes.
  Future<void> setCrashlytics(bool enable) async {
    try {
      await _channel
          .invokeMethod('setCrashlytics', enable)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      commonPrint.log('setCrashlytics error: $e');
    }
  }

  /// Persist quickStart-equivalent params so tile/widget/Always-on can
  /// cold-start without Flutter via FlVpnService.coldStart().
  Future<void> saveParamsForColdStart({
    required InitParams initParams,
    required SetupParams setupParams,
    required CoreState state,
  }) async {
    try {
      await _channel
          .invokeMethod('saveParams', <String, String>{
            'init': json.encode(initParams),
            'params': json.encode(setupParams),
            'state': json.encode(state),
          })
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      commonPrint.log('saveParamsForColdStart error: $e');
    }
  }
}

ClashLib? get clashLib => Platform.isAndroid ? ClashLib() : null;
