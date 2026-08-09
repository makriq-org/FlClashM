import 'dart:io';

class FlClashHttpOverrides extends HttpOverrides {
  // Application traffic enters mihomo through the action IPC transport, never
  // through a local proxy listener. HttpOverrides remains direct for bootstrap
  // requests made before the core has an active runtime configuration.
  static String handleFindProxy(Uri url) => 'DIRECT';

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = handleFindProxy;
}
