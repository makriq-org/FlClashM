import 'access_control_service.dart';
import 'android_shell_service.dart';
import 'app_update_service.dart';

export 'access_control_service.dart';
export 'android_shell_service.dart';
export 'app_update_service.dart';

class ProductServices {
  const ProductServices({
    this.accessControl = const AccessControlService(),
    this.androidShell = const AndroidShellService(),
    this.appUpdate = const AppUpdateService(),
  });

  final AccessControlService accessControl;
  final AndroidShellService androidShell;
  final AppUpdateService appUpdate;
}

const productServices = ProductServices();
