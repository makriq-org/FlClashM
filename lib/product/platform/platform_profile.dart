import 'dart:io';

import 'package:flclashx/enum/enum.dart';

enum ProductPlatformKind { android, unsupported }

class ProductPlatformProfile {
  const ProductPlatformProfile._({
    required this.kind,
    required this.hostPlatform,
    required this.supported,
    required this.preferCompactNavigation,
  });

  factory ProductPlatformProfile.current() {
    if (Platform.isAndroid) {
      return const ProductPlatformProfile._(
        kind: ProductPlatformKind.android,
        hostPlatform: SupportPlatform.Android,
        supported: true,
        preferCompactNavigation: true,
      );
    }

    return ProductPlatformProfile._(
      kind: ProductPlatformKind.unsupported,
      hostPlatform: SupportPlatform.currentPlatform,
      supported: false,
      preferCompactNavigation: true,
    );
  }

  final ProductPlatformKind kind;
  final SupportPlatform hostPlatform;
  final bool supported;
  final bool preferCompactNavigation;

  bool get isAndroid => kind == ProductPlatformKind.android;

  bool get isUnsupported => kind == ProductPlatformKind.unsupported;

  NavigationItemMode resolveNavigationMode(double viewWidth) =>
      NavigationItemMode.mobile;
}

final productPlatform = ProductPlatformProfile.current();
