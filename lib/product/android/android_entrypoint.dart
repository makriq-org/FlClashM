import 'package:flclashx/product/services/product_services.dart';

class AndroidEntrypoint {
  AndroidEntrypoint._();
  static final AndroidEntrypoint instance = AndroidEntrypoint._();

  // Tile and widget actions are submitted to Go natively; the UI only signals
  // that it is ready to render tile state.
  Future<void> init() => productServices.androidShell.signalServiceReady();
}

final androidEntrypoint = AndroidEntrypoint.instance;
