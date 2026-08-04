import 'dart:io';

import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/android/android_runtime_access_policy.dart';
import 'package:flclashx/product/platform/desktop_platform_services.dart';
import 'package:flclashx/product/platform/platform_profile.dart';
import 'package:flclashx/product/platform/product_install_layout.dart';
import 'package:flclashx/product/platform/product_platform_composition.dart';
import 'package:flclashx/product/runtime/runtime_registry.dart';
import 'package:flclashx/product/runtime/runtime_types.dart';
import 'package:flclashx/product/security/android_security_policy.dart';
import 'package:flclashx/product/services/android_shell_service.dart';
import 'package:flclashx/product/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProductPlatformProfile', () {
    test('recognizes every supported product host', () {
      expect(
        ProductPlatformProfile.fromOperatingSystem('android').kind,
        ProductPlatformKind.android,
      );
      expect(
        ProductPlatformProfile.fromOperatingSystem('linux').kind,
        ProductPlatformKind.linux,
      );
      expect(
        ProductPlatformProfile.fromOperatingSystem('windows').kind,
        ProductPlatformKind.windows,
      );
      expect(
        ProductPlatformProfile.fromOperatingSystem('macos').kind,
        ProductPlatformKind.macos,
      );
    });

    test('rejects an unsupported host with a useful error', () {
      final profile = ProductPlatformProfile.fromOperatingSystem('freebsd');

      expect(profile.supported, isFalse);
      expect(profile.unsupportedMessage, contains('freebsd'));
      expect(
        () => ProductPlatformComposition.forProfile(profile),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('ProductPlatformComposition', () {
    test('preserves Android service and security implementations', () {
      final composition = ProductPlatformComposition.forProfile(
        ProductPlatformProfile.fromOperatingSystem('android'),
      );

      expect(composition.securityPolicy, isA<AndroidSecurityPolicy>());
      expect(
        composition.services.accessControl.platform,
        isA<AndroidRuntimeAccessPolicy>(),
      );
      expect(composition.services.androidShell, isA<AndroidShellService>());
      expect(composition.services.appUpdate, isA<AppUpdateService>());
      expect(composition.mihomoAvailability.isSupported, isTrue);
    });

    test('uses channel-free desktop stubs and rejects TUN', () async {
      final composition = ProductPlatformComposition.forProfile(
        ProductPlatformProfile.fromOperatingSystem('linux'),
      );

      expect(
        composition.services.accessControl.platform,
        isA<DesktopRuntimeAccessPolicy>(),
      );
      expect(composition.services.androidShell, isA<DesktopShellService>());
      expect(composition.services.appUpdate, isA<DesktopAppUpdateService>());
      expect(composition.mihomoAvailability.isSupported, isFalse);
      final runtimeRegistry = RuntimeRegistry.flClashM(
        readAccessControl: () => const AccessControl(),
        mihomoAvailability: composition.mihomoAvailability,
      );
      expect(
        runtimeRegistry.resolveSelection,
        throwsA(isA<UnsupportedRuntimeSelectionException>()),
      );
      await expectLater(
        composition.services.accessControl.startVpn(
          accessControl: const AccessControl(enable: true),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('desktop source never imports Android channels', () async {
      final source = await File(
        'lib/product/platform/desktop_platform_services.dart',
      ).readAsString();

      expect(source, isNot(contains('MethodChannel')));
      expect(source, isNot(contains("../android/")));
    });
  });

  test('keeps one stable runtime artifact layout', () {
    expect(ProductInstallLayout.desktopApplicationId, 'app.flclashm.client');
    expect(
      ProductInstallLayout.desktopHelperName,
      'app.flclashm.client.helper',
    );
    expect(
      ProductInstallLayout.artifactPath(
        installRoot: '/opt/flclashm',
        target: 'linux',
        architecture: 'x86_64',
        artifact: ProductInstallLayout.stormdnsArtifact,
      ),
      '/opt/flclashm/runtimes/linux/x86_64/stormdns',
    );
  });
}
