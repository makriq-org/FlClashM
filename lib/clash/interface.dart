import 'dart:async';
import 'dart:convert';

import 'package:flclashx/clash/message.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';

mixin ClashInterface {
  Future<bool> preload();

  Future<bool> shutdown();

  Future<bool> get isInit;

  Future<bool> forceGc();

  Future<String> asyncTestDelay(String url, String proxyName);

  Future<void> healthCheck([String groupName = '']);

  FutureOr<Map> getProxies();

  FutureOr<String> getExternalProviders();

  FutureOr<String>? getExternalProvider(String externalProviderName);

  FutureOr<String> getTraffic();

  FutureOr<String> getTotalTraffic();

  FutureOr<String> getCountryCode(String ip);

  FutureOr<String> getMemory();

  FutureOr<String> getCoreVersion();

  startLog();

  stopLog();

  Future<bool> crash();

  FutureOr<String> getConnections();

  Future<bool> setUiActive(bool active);

  FutureOr<Map> tunnelHTTPRequest(
    String params, {
    Duration? timeout,
  });

  FutureOr<Map> getRuntimeSnapshot();

  FutureOr<bool> cancelTunnelHTTPRequest(String requestId);
}

mixin AndroidClashInterface {
  Future<String> getAndroidVpnOptions();

  Future<String> getAppliedAndroidVpnOptions();

  Future<String> getCurrentProfileName();

  Future<DateTime?> getRunTime();
}

abstract class ClashHandlerInterface with ClashInterface {
  Map<String, Completer> callbackCompleterMap = {};

  /// Per-call type-appropriate default value, so a failed call can complete the
  /// typed completer with the right default instead of `null` (which throws a
  /// TypeError on a non-nullable type and strands the caller until timeout).
  Map<String, dynamic> callbackDefaultMap = {};

  Future<void> handleResult(ActionResult result) async {
    final completer = callbackCompleterMap[result.id];
    try {
      switch (result.method) {
        case ActionMethod.message:
          clashMessage.controller.add(result.data);
          completer?.complete(true);
          return;
        case ActionMethod.getConfig:
          completer?.complete(result.toResult);
          return;
        default:
          completer?.complete(result.data);
          return;
      }
    } catch (e) {
      commonPrint.log("${result.id} error $e");
      // Type mismatch (e.g. the remote sent a bool for a Completer<String>):
      // completing with the wrong type threw above and left the completer
      // pending until the 30s safeFuture timeout — a "random" 30s freeze of
      // whatever call this was. Complete with the typed default now.
      if (completer != null && !completer.isCompleted) {
        completer.complete(callbackDefaultMap[result.id]);
      }
    }
  }

  sendMessage(String message);

  reStart();

  FutureOr<bool> destroy();

  Future<T> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
    FutureOr<T> Function()? onTimeout,
    T? defaultValue,
  }) async {
    final id = "${method.name}#${utils.id}";

    callbackCompleterMap[id] = Completer<T>();

    dynamic mDefaultValue = defaultValue;
    if (mDefaultValue == null) {
      if (T == String) {
        mDefaultValue = "";
      } else if (T == bool) {
        mDefaultValue = false;
      } else if (T == Map) {
        mDefaultValue = {};
      }
    }
    callbackDefaultMap[id] = mDefaultValue;

    sendMessage(
      json.encode(
        Action(
          id: id,
          method: method,
          data: data,
        ),
      ),
    );

    return (callbackCompleterMap[id]! as Completer<T>).safeFuture(
      timeout: timeout,
      onLast: () {
        callbackCompleterMap.remove(id);
        callbackDefaultMap.remove(id);
      },
      onTimeout: onTimeout ??
          () => mDefaultValue as T,
      functionName: id,
    ) as Future<T>;
  }

  @override
  Future<bool> setUiActive(bool active) => invoke<bool>(
      method: ActionMethod.setUiActive,
      data: active,
      // Short timeout so an older core without this handler degrades silently
      // instead of leaving a pending completer.
      timeout: const Duration(seconds: 2),
    );

  @override
  Future<Map> tunnelHTTPRequest(
    String params, {
    Duration? timeout,
  }) =>
      invoke<Map>(
        method: ActionMethod.tunnelHTTPRequest,
        data: params,
        timeout: timeout ?? const Duration(seconds: 70),
        defaultValue: const {
          'error': 'tunnel HTTP request timed out',
        },
      );

  @override
  Future<Map> getRuntimeSnapshot() => invoke<Map>(
        method: ActionMethod.getRuntimeSnapshot,
        timeout: const Duration(seconds: 5),
        defaultValue: const {},
      );

  @override
  Future<bool> cancelTunnelHTTPRequest(String requestId) => invoke<bool>(
        method: ActionMethod.cancelTunnelHTTPRequest,
        data: requestId,
        timeout: const Duration(seconds: 2),
      );

  @override
  Future<bool> get isInit => invoke<bool>(
        method: ActionMethod.getIsInit,
      );

  @override
  Future<bool> forceGc() => invoke<bool>(
        method: ActionMethod.forceGc,
      );

  @override
  Future<bool> crash() => invoke<bool>(
      method: ActionMethod.crash,
    );

  @override
  Future<Map> getProxies() => invoke<Map>(
      method: ActionMethod.getProxies,
      timeout: const Duration(seconds: 5),
    );

  @override
  FutureOr<String> getExternalProviders() => invoke<String>(
      method: ActionMethod.getExternalProviders,
    );

  @override
  FutureOr<String> getExternalProvider(String externalProviderName) => invoke<String>(
      method: ActionMethod.getExternalProvider,
      data: externalProviderName,
    );

  @override
  FutureOr<String> getConnections() => invoke<String>(
      method: ActionMethod.getConnections,
    );

  @override
  FutureOr<String> getTotalTraffic() => invoke<String>(
      method: ActionMethod.getTotalTraffic,
    );

  @override
  FutureOr<String> getTraffic() => invoke<String>(
      method: ActionMethod.getTraffic,
    );

  @override
  void startLog() {
    invoke(method: ActionMethod.startLog);
  }

  @override
  void stopLog() {
    invoke<bool>(
      method: ActionMethod.stopLog,
    );
  }

  @override
  Future<String> asyncTestDelay(String url, String proxyName) {
    final delayParams = {
      "proxy-name": proxyName,
      "timeout": httpTimeoutDuration.inMilliseconds,
      "test-url": url,
    };
    return invoke<String>(
      method: ActionMethod.asyncTestDelay,
      data: json.encode(delayParams),
      timeout: const Duration(
        milliseconds: 6000,
      ),
      onTimeout: () => json.encode(
          Delay(
            name: proxyName,
            value: -1,
            url: url,
          ),
        ),
    );
  }

  @override
  Future<void> healthCheck([String groupName = '']) => invoke<String>(
      method: ActionMethod.healthCheck,
      data: groupName,
      timeout: const Duration(seconds: 30),
    );

  @override
  FutureOr<String> getCountryCode(String ip) => invoke<String>(
      method: ActionMethod.getCountryCode,
      data: ip,
    );

  @override
  FutureOr<String> getMemory() => invoke<String>(
      method: ActionMethod.getMemory,
    );

  @override
  FutureOr<String> getCoreVersion() => invoke<String>(
      method: ActionMethod.getCoreVersion,
    );
}
