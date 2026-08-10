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
import 'package:flclashx/product/services/desktop_app_update_bridge.dart';
import 'package:flclashx/state.dart';
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

    test('uses desktop updater and keeps unreleased TUN unavailable', () async {
      final composition = ProductPlatformComposition.forProfile(
        ProductPlatformProfile.fromOperatingSystem('linux'),
      );

      expect(
        composition.services.accessControl.platform,
        isA<DesktopRuntimeAccessPolicy>(),
      );
      expect(composition.services.androidShell, isA<DesktopShellService>());
      final updater = composition.services.appUpdate;
      expect(updater, isA<AppUpdateService>());
      expect((updater as AppUpdateService).platform,
          isA<DesktopAppUpdateBridge>());
      expect(composition.mihomoAvailability.isSupported, isFalse);
      expect(await composition.bootstrap.preloadMihomo(), isFalse);
      final runtimeRegistry = RuntimeRegistry.flClashM(
        readAccessControl: () => const AccessControl(),
        mihomoAvailability: composition.mihomoAvailability,
      );
      expect(
        runtimeRegistry.resolveSelection,
        throwsA(isA<UnsupportedRuntimeSelectionException>()),
      );
      expect(globalState.engineManager.isStarted, isFalse);
      expect(
        globalState.runtimeRegistry.resolveSelection,
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

  test('uses the stable desktop ID and runtime layout in every build target',
      () async {
    final sources = await Future.wait([
      File('lib/common/path.dart').readAsString(),
      File('linux/CMakeLists.txt').readAsString(),
      File('windows/CMakeLists.txt').readAsString(),
      File('macos/Runner/Configs/AppInfo.xcconfig').readAsString(),
      File('macos/Runner.xcodeproj/project.pbxproj').readAsString(),
    ]);
    final runtimeResolver = sources[0];
    final linux = sources[1];
    final windows = sources[2];
    final macosConfig = sources[3];
    final macosProject = sources[4];

    expect(runtimeResolver, contains('ProductInstallLayout.mihomoArtifact'));
    expect(runtimeResolver, contains('ProductInstallLayout.helperArtifact'));
    expect(linux, contains('set(APPLICATION_ID "app.flclashm.client")'));
    expect(linux, contains(r'/runtimes/linux/${RUNTIME_ARCHITECTURE}'));
    expect(linux, contains('RENAME "mihomo"'));
    expect(windows, contains(r'/runtimes/windows/${RUNTIME_ARCHITECTURE}'));
    expect(windows, contains('RENAME "mihomo.exe"'));
    expect(windows, contains('RENAME "app.flclashm.client.helper.exe"'));
    expect(macosConfig,
        contains('PRODUCT_BUNDLE_IDENTIFIER = app.flclashm.client'));
    expect(
      macosProject,
      contains(r'Contents/runtimes/macos/$(CURRENT_ARCH)/mihomo'),
    );
  });
}
