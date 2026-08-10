import 'dart:io';

import 'package:flclashx/enum/enum.dart';

enum ProductPlatformKind { android, linux, windows, macos, unsupported }

/// The supported product hosts. This is intentionally independent from Flutter
/// target-platform heuristics so composition has one deterministic input.
class ProductPlatformProfile {
  const ProductPlatformProfile._({
    required this.kind,
    required this.hostPlatform,
    required this.operatingSystem,
    required this.supported,
    required this.preferCompactNavigation,
  });

  factory ProductPlatformProfile.current() =>
      ProductPlatformProfile.fromOperatingSystem(Platform.operatingSystem);

  factory ProductPlatformProfile.fromOperatingSystem(String operatingSystem) =>
      switch (operatingSystem.toLowerCase()) {
        'android' => const ProductPlatformProfile._(
            kind: ProductPlatformKind.android,
            hostPlatform: SupportPlatform.Android,
            operatingSystem: 'android',
            supported: true,
            preferCompactNavigation: true,
          ),
        'linux' => const ProductPlatformProfile._(
            kind: ProductPlatformKind.linux,
            hostPlatform: SupportPlatform.Linux,
            operatingSystem: 'linux',
            supported: true,
            preferCompactNavigation: false,
          ),
        'windows' => const ProductPlatformProfile._(
            kind: ProductPlatformKind.windows,
            hostPlatform: SupportPlatform.Windows,
            operatingSystem: 'windows',
            supported: true,
            preferCompactNavigation: false,
          ),
        'macos' => const ProductPlatformProfile._(
            kind: ProductPlatformKind.macos,
            hostPlatform: SupportPlatform.MacOS,
            operatingSystem: 'macos',
            supported: true,
            preferCompactNavigation: false,
          ),
        _ => ProductPlatformProfile._(
            kind: ProductPlatformKind.unsupported,
            hostPlatform: _hostPlatformOrAndroid(),
            operatingSystem: operatingSystem,
            supported: false,
            preferCompactNavigation: true,
          ),
      };

  final ProductPlatformKind kind;
  final SupportPlatform hostPlatform;
  final String operatingSystem;
  final bool supported;
  final bool preferCompactNavigation;

  bool get isAndroid => kind == ProductPlatformKind.android;

  bool get isDesktop => switch (kind) {
        ProductPlatformKind.linux ||
        ProductPlatformKind.windows ||
        ProductPlatformKind.macos =>
          true,
        _ => false,
      };

  bool get isUnsupported => kind == ProductPlatformKind.unsupported;

  NavigationItemMode resolveNavigationMode(double viewWidth) =>
      preferCompactNavigation
          ? NavigationItemMode.mobile
          : NavigationItemMode.desktop;

  String get unsupportedMessage =>
      'FlClashM does not support `$operatingSystem`. '
      'Supported platforms: Android, Linux, Windows, macOS.';

  static SupportPlatform _hostPlatformOrAndroid() {
    try {
      return SupportPlatform.currentPlatform;
    } catch (_) {
      // SupportPlatform predates web/other hosts. The value is only kept for
      // legacy UI APIs; unsupported hosts fail before the application starts.
      return SupportPlatform.Android;
    }
  }
}

final productPlatform = ProductPlatformProfile.current();
