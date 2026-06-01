import 'dart:async';

import 'package:app_links/app_links.dart';

import 'print.dart';

typedef InstallConfigCallBack = void Function(String url);

class LinkManager {
  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }

  LinkManager._internal() {
    _appLinks = AppLinks();
  }
  static LinkManager? _instance;
  late AppLinks _appLinks;
  StreamSubscription? subscription;
  Uri? _lastHandledUri;
  DateTime? _lastHandledAt;

  Future<void> initAppLinksListen(installConfigCallBack) async {
    commonPrint.log("initAppLinksListen");
    destroy();
    subscription = _appLinks.uriLinkStream.listen(
      (uri) => _handleInstallConfigUri(uri, installConfigCallBack),
    );
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      _handleInstallConfigUri(initialUri, installConfigCallBack);
    }
  }

  void _handleInstallConfigUri(
    Uri uri,
    InstallConfigCallBack installConfigCallBack,
  ) {
    final now = DateTime.now();
    if (_lastHandledUri == uri &&
        _lastHandledAt != null &&
        now.difference(_lastHandledAt!) < const Duration(seconds: 1)) {
      return;
    }
    _lastHandledUri = uri;
    _lastHandledAt = now;
    commonPrint.log('onAppLink: $uri');
    if (uri.host != 'install-config') {
      return;
    }
    final url = uri.queryParameters['url'];
    if (url != null) {
      installConfigCallBack(url);
    }
  }

  void destroy() {
    if (subscription != null) {
      subscription?.cancel();
      subscription = null;
    }
  }
}

final linkManager = LinkManager();
