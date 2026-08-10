import 'dart:io';

import '../../clash/core.dart';
import '../../common/android.dart';
import '../../common/window.dart';
import '../android/android_entrypoint.dart';
import '../android/android_platform.dart';
import '../runtime/runtime_types.dart';
import '../security/android_security_policy.dart';
import '../security/security_policy.dart';
import '../services/desktop_app_update_bridge.dart';
import '../services/product_services.dart';
import 'desktop_platform_services.dart';
import 'desktop_security_policy.dart';
import 'platform_profile.dart';

abstract interface class ProductPlatformBootstrap {
  Future<bool> preloadMihomo();

  Future<void> initialize({required int hostVersion});
}

class AndroidPlatformBootstrap implements ProductPlatformBootstrap {
  const AndroidPlatformBootstrap();

  @override
  Future<bool> preloadMihomo() => clashCore.preload();

  @override
  Future<void> initialize({required int hostVersion}) async {
    await android?.init();
    await androidEntrypoint.init();
  }
}

class DesktopPlatformBootstrap implements ProductPlatformBootstrap {
  const DesktopPlatformBootstrap();

  @override
  Future<bool> preloadMihomo() => clashCore.preload();

  @override
  Future<void> initialize({required int hostVersion}) async {
    await window?.init(hostVersion);
  }
}

class ProductPlatformCapabilities {
  const ProductPlatformCapabilities({
    required this.tunConfiguration,
    required this.systemProxy,
    required this.androidAccessControl,
  });

  final bool tunConfiguration;
  final bool systemProxy;
  final bool androidAccessControl;
}

/// The only product composition root. New platforms provide their platform
/// boundary objects here rather than letting desktop code reach Android bridges.
class ProductPlatformComposition {
  ProductPlatformComposition._({
    required this.profile,
    required this.services,
    required this.securityPolicy,
    required this.bootstrap,
    required this.capabilities,
    required this.mihomoAvailability,
  });

  factory ProductPlatformComposition.forProfile(
    ProductPlatformProfile profile,
  ) {
    if (!profile.supported) {
      throw UnsupportedError(profile.unsupportedMessage);
    }

    if (profile.isAndroid) {
      return ProductPlatformComposition._(
        profile: profile,
        services: ProductServices(
          accessControl: AccessControlService(
            platform: androidPlatform.runtimeAccess,
          ),
          androidShell: AndroidShellService(
            platform: androidPlatform.shell,
            foregroundNotification: androidPlatform.foregroundNotification,
          ),
          appUpdate: AppUpdateService(platform: androidPlatform.updateBridge),
        ),
        securityPolicy: const AndroidSecurityPolicy(),
        bootstrap: const AndroidPlatformBootstrap(),
        capabilities: const ProductPlatformCapabilities(
          tunConfiguration: false,
          systemProxy: false,
          androidAccessControl: true,
        ),
        mihomoAvailability: const RuntimeAvailability.supported(
          updatePath:
              'Bundled Android core is built by setup.dart into libclash/android.',
          rollbackPath:
              'Fallback stays on the bundled mihomo path and current cold-start snapshot.',
        ),
      );
    }

    final updateEnvironment = DesktopUpdateEnvironment.forOperatingSystem(
      profile.operatingSystem,
      packageManagedLinux:
          profile.kind == ProductPlatformKind.linux &&
          (Platform.environment['APPIMAGE']?.trim().isEmpty ?? true),
    );
    return ProductPlatformComposition._(
      profile: profile,
      services: ProductServices(
        accessControl: const AccessControlService(
          platform: DesktopRuntimeAccessPolicy(),
        ),
        androidShell: const DesktopShellService(),
        appUpdate: AppUpdateService(
          platform: DesktopAppUpdateBridge(
            environment: updateEnvironment,
            installHandoff: profile.kind == ProductPlatformKind.linux
                ? LinuxAppImageInstallHandoff()
                : const DeferredDesktopInstallHandoff(),
          ),
          packageSelector: DesktopAppUpdatePackageSelector(
            environment: updateEnvironment,
          ),
        ),
      ),
      securityPolicy: DesktopSecurityPolicy.currentInstall(),
      bootstrap: const DesktopPlatformBootstrap(),
      capabilities: const ProductPlatformCapabilities(
        tunConfiguration: false,
        systemProxy: true,
        androidAccessControl: false,
      ),
      mihomoAvailability: const RuntimeAvailability.supported(
        updatePath:
            'Bundled desktop runtimes are updated with the application.',
        rollbackPath: 'Roll back the complete application bundle.',
      ),
    );
  }

  final ProductPlatformProfile profile;
  final ProductServices services;
  final SecurityPolicy securityPolicy;
  final ProductPlatformBootstrap bootstrap;
  final ProductPlatformCapabilities capabilities;
  final RuntimeAvailability mihomoAvailability;
}

final productPlatformComposition = ProductPlatformComposition.forProfile(
  productPlatform,
);
