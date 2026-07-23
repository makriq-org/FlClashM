import 'access_control_service.dart';
import 'android_shell_service.dart';
import 'app_update_service.dart';

export '../widgets/access_control_notice.dart';
export 'access_control_service.dart';
export 'android_shell_service.dart';
export 'app_update_service.dart';
export 'product_contributors.dart';

class ProductServices {
  ProductServices({
    this.accessControl = const AccessControlService(),
    AndroidShellService? androidShell,
    this.appUpdate = const AppUpdateService(),
  }) : androidShell = androidShell ?? AndroidShellService();

  final AccessControlService accessControl;
  final AndroidShellService androidShell;
  final AppUpdateService appUpdate;
}

final productServices = ProductServices();
