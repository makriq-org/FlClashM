import 'dart:io';

import 'package:flclashm/product/services/product_services.dart';
import 'package:flclashm/state.dart';

class Android {
  Future<void> init() async {
    productServices.androidShell.installExitHook(() async {
      if (!globalState.isInit) {
        return;
      }
      await globalState.appController.savePreferences();
    });
  }
}

final android = Platform.isAndroid ? Android() : null;
