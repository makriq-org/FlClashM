import '../platform/product_platform_composition.dart';
import 'access_control_service.dart';
import 'android_shell_service.dart';
import 'app_update_service.dart';
import 'product_shell_service.dart';
import 'product_update_service.dart';

export '../widgets/access_control_notice.dart';
export 'access_control_service.dart';
export 'android_shell_service.dart';
export 'app_update_service.dart';
export 'product_contributors.dart';

class ProductServices {
  ProductServices({
    this.accessControl = const AccessControlService(),
    ProductShellService? androidShell,
    ProductUpdateService? appUpdate,
  })  : androidShell = androidShell ?? AndroidShellService(),
        appUpdate = appUpdate ?? const AppUpdateService();

  final AccessControlService accessControl;

  /// Kept as `androidShell` for stable base touchpoints. Its implementation is
  /// selected only by [ProductPlatformComposition].
  final ProductShellService androidShell;
  final ProductUpdateService appUpdate;
}

final productServices = productPlatformComposition.services;
