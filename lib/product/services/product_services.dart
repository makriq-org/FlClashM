import 'access_control_service.dart';
import 'app_update_service.dart';

export 'access_control_service.dart';
export 'app_update_service.dart';

class ProductServices {
  const ProductServices({
    this.accessControl = const AccessControlService(),
    this.appUpdate = const AppUpdateService(),
  });

  final AccessControlService accessControl;
  final AppUpdateService appUpdate;
}

const productServices = ProductServices();
