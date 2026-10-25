import 'package:flclashx/common/constant.dart';
import 'package:flclashx/common/print.dart';
import 'package:flclashx/common/system.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart' show ProxyState;
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop && !safeModeBuild ? Proxy() : null;

final systemProxyQueue = proxy == null ? null : SystemProxyQueue(proxy!);

/// Exit's stop goes through the same queue as every other change, so a start
/// still waiting behind a slow call cannot turn the proxy back on after it.
class SystemProxyQueue {
  final Proxy _proxy;
  Future<void> _tail = Future.value();
  bool _closed = false;

  SystemProxyQueue(this._proxy);

  Future<void> apply(ProxyState state) {
    return _enqueue(() async {
      if (_closed) {
        return;
      }
      final applied = state.isStart && state.systemProxy
          ? await _proxy.startProxy(state.port, state.bassDomain)
          : await _proxy.stopProxy();
      if (applied != true) {
        commonPrint.log(
          'update system proxy failed',
          logLevel: LogLevel.warning,
        );
      }
    });
  }

  Future<void> close() {
    _closed = true;
    return _enqueue(() async {
      await _proxy.stopProxy();
    });
  }

  Future<void> _enqueue(Future<void> Function() task) {
    return _tail = _tail.then((_) => task()).catchError((Object error) {
      commonPrint.log(
        'update system proxy failed: $error',
        logLevel: LogLevel.warning,
      );
    });
  }
}

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  return isWindows ? 'set \$env:all_proxy=$url' : 'export all_proxy=$url';
}
