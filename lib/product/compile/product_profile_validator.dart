import 'package:flclashx/models/models.dart';

import 'built_in_proxy_compiler.dart';
import 'profile_yaml.dart';

class ProductProfileValidator {
  const ProductProfileValidator({
    this.builtInProxyCompiler = const BuiltInProxyCompiler(),
  });

  final BuiltInProxyCompiler builtInProxyCompiler;

  Map<String, dynamic> normalizeForValidation(String text) {
    final rawConfig = loadProfileConfigFromString(text);
    return builtInProxyCompiler
        .compile(
          rawConfig: rawConfig,
          patchConfig: const ClashConfig(),
        )
        .config;
  }
}
