import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/state.dart';

class FlClashHttpOverrides extends HttpOverrides {
  static bool _isLoopbackHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    if (normalized == 'localhost' || normalized == localhost) {
      return true;
    }
    final address = InternetAddress.tryParse(normalized);
    return address?.isLoopback ?? false;
  }

  static String handleFindProxy(Uri url) {
    if (_isLoopbackHost(url.host)) {
      return "DIRECT";
    }
    final isStart = globalState.appState.runTime != null;
    if (!isStart) return "DIRECT";
    // When TUN is handling traffic, let the OS network stack send the request
    // so it gets captured by TUN and processed by the core via rules. This
    // avoids depending on the mixed-port inbound at all, which removes issues
    // with inbound `authentication` rejecting the app's own HTTP traffic and
    // also works when the user sets mixed-port to 0 (disabled).
    // Loop prevention: clash-core outbound sockets are protected/bound outside
    // TUN (on Android via TunInterface.protect, on desktop via binding the
    // physical interface).
    //
    // On Android the service is always a VpnService (TUN), so when it's
    // running the traffic is already captured. `realTunEnable` is a desktop-
    // only flag (it tracks admin authorization for TUN on Win/macOS/Linux)
    // and stays false on Android even though TUN is effectively on.
    final tunHandlesTraffic =
        Platform.isAndroid || globalState.appState.realTunEnable;
    if (tunHandlesTraffic) {
      return "DIRECT";
    }
    final port = globalState.config.patchClashConfig.mixedPort;
    if (port == 0) {
      // Mixed-port is disabled and TUN isn't handling traffic — we have no
      // inbound to route through. Go DIRECT; at worst the request leaks, but
      // that's strictly better than trying PROXY localhost:0 which hangs.
      return "DIRECT";
    }
    return "PROXY localhost:$port";
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = handleFindProxy;
}
