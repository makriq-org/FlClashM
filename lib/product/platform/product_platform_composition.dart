import 'dart:io';

import '../../clash/core.dart';
import '../../common/android.dart';
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

  Future<void> initialize();
}

class AndroidPlatformBootstrap implements ProductPlatformBootstrap {
  const AndroidPlatformBootstrap();

  @override
  Future<bool> preloadMihomo() => clashCore.preload();

  @override
  Future<void> initialize() async {
    await android?.init();
    await androidEntrypoint.init();
  }
}

class DesktopPlatformBootstrap implements ProductPlatformBootstrap {
  const DesktopPlatformBootstrap();

  @override
  Future<bool> preloadMihomo() async => false;

  @override
  Future<void> initialize() async {}
}

/// The only product composition root. New platforms provide their platform
/// boundary objects here rather than letting desktop code reach Android bridges.
class ProductPlatformComposition {
  ProductPlatformComposition._({
    required this.profile,
    required this.services,
    required this.securityPolicy,
    required this.bootstrap,
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
          platform: DesktopAppUpdateBridge(environment: updateEnvironment),
          packageSelector: DesktopAppUpdatePackageSelector(
            environment: updateEnvironment,
          ),
        ),
      ),
      securityPolicy: const DesktopSecurityPolicy(),
      bootstrap: const DesktopPlatformBootstrap(),
      mihomoAvailability: RuntimeAvailability.unsupported(
        reason: desktopCapabilityMessage(DesktopCapability.tun),
        updatePath: 'Desktop runtime integration has not been released yet.',
        rollbackPath: 'Keep using the Android runtime until desktop TUN ships.',
      ),
    );
  }

  final ProductPlatformProfile profile;
  final ProductServices services;
  final SecurityPolicy securityPolicy;
  final ProductPlatformBootstrap bootstrap;
  final RuntimeAvailability mihomoAvailability;
}

final productPlatformComposition = ProductPlatformComposition.forProfile(
  productPlatform,
);
